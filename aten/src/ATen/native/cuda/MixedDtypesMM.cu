#include <ATen/ATen.h>
#include <ATen/core/Tensor.h>
#include <ATen/cuda/CUDAUtils.h>

#ifndef USE_ROCM
#include <cuda_runtime.h>
#include <cutlass/cutlass.h>
#include <cutlass/tensor_ref.h>

#include <cutlass/gemm/device/gemm_universal_base.h>
#include <cutlass/gemm/kernel/default_gemm.h>

#include <cutlass_extensions/epilogue_helpers.h>
#include <cutlass_extensions/gemm/kernel/default_fpA_intB_traits.h>
#include <cutlass_extensions/gemm/kernel/fpA_intB_gemm.h>
#include <cutlass_extensions/gemm/threadblock/default_mma.h>
#endif

#ifndef USE_ROCM
#define CUTLASS_STATUS_CHECK(status)                                      \
  {                                                                       \
    TORCH_CHECK(status == cutlass::Status::kSuccess,                      \
                "Got CUTLASS error: ", cutlassGetStatusString(status));   \
  }
#endif

namespace at {
namespace native {

#ifndef USE_ROCM
template<typename ElementInputA>
Tensor
mixed_dtypes_mm_dispatch_dtype(
    const Tensor& input, const Tensor& weight, const Tensor& scale,
    const Tensor& bias) {
  const int length_m = input.size(0);
  const int length_k = weight.size(0);
  const int length_n = weight.size(1);

  using ElementInputB = uint8_t;
  using ElementOutput = ElementInputA;

  using SmArch = cutlass::arch::Sm80;
  using ThreadblockShape = cutlass::gemm::GemmShape<32, 128, 64>;
  using WarpShape = cutlass::gemm::GemmShape<32, 32, 64>;
  using InstructionShape = cutlass::gemm::GemmShape<16, 8, 16>;
  using ThreadblockSwizzle = cutlass::gemm::threadblock::GemmIdentityThreadblockSwizzle<>;
  using Operator = cutlass::arch::OpMultiplyAddDequantizeInterleavedBToA;

  constexpr auto ThreadblockK = 64;
  constexpr auto ElementsPerCacheLine = 128 * 8 / cutlass::sizeof_bits<uint8_t>::value;
  constexpr auto ColumnsInterleaved   = ElementsPerCacheLine / ThreadblockK;

  using LayoutInputA = cutlass::layout::RowMajor;
  using LayoutInputB = cutlass::layout::ColumnMajorTileInterleave<ThreadblockK, ColumnsInterleaved>;
  using LayoutOutput = LayoutInputA;

  constexpr auto ElementsPerAccessA = 128 / cutlass::sizeof_bits<ElementInputA>::value;
  constexpr auto ElementsPerAccessB = 128 / cutlass::sizeof_bits<ElementInputB>::value;
  constexpr auto ElementsPerAccessC = ElementsPerAccessA;
  constexpr auto Stages = 4;
  constexpr auto SplitKFactor = 1; // Wrong outputs if !=1, even if
                                   // GemmFpAIntB instantiated with
                                   // SplitKSerial set to false.

  // Check for current CUTLASS limitations w.r.t. weight sizes.
  TORCH_CHECK(length_k % 64 == 0 && length_n % 64 == 0,
              "mixed_dtypes_mm_dispatch_dtype: Number of rows/columns of the "
              "weight matrix must be divisible by ", 64);

  using ElementAccumulator = float;

  using EpilogueTag = fastertransformer::EpilogueOpBias;
  using EpilogueOp = typename fastertransformer::Epilogue<
      ElementOutput,
      ElementsPerAccessC,
      ElementAccumulator,
      EpilogueTag>::Op;

  using DefaultGemmKernel = typename cutlass::gemm::kernel::DefaultGemm<
      ElementInputA,
      LayoutInputA,
      ElementsPerAccessA,
      ElementInputB,
      LayoutInputB,
      ElementsPerAccessB,
      ElementOutput,
      LayoutOutput,
      ElementAccumulator,
      cutlass::arch::OpClassTensorOp,
      SmArch,
      ThreadblockShape,
      WarpShape,
      InstructionShape,
      EpilogueOp,
      ThreadblockSwizzle,
      Stages,
      true,
      Operator>::GemmKernel;
  using GemmKernel = cutlass::gemm::kernel::GemmFpAIntB<
      typename DefaultGemmKernel::Mma,
      typename DefaultGemmKernel::Epilogue,
      typename DefaultGemmKernel::ThreadblockSwizzle,
      SmArch,
      DefaultGemmKernel::kSplitKSerial>;

  using Gemm = cutlass::gemm::device::GemmUniversalBase<GemmKernel>;

  auto output = input.new_empty({length_m, length_n});

  const auto ldb = length_k * GemmKernel::kInterleave;

  typename Gemm::Arguments arguments(
      {length_m, length_n, length_k},
      {(ElementInputA*)input.data_ptr(), length_k},
      {(ElementInputB*)weight.data_ptr(), ldb},
      {(ElementInputA*)scale.data_ptr(), 0},
      {(ElementInputA*)bias.data_ptr(), 0},
      {(ElementOutput*)output.data_ptr(), length_n},
      SplitKFactor,
      {ElementAccumulator(1.f), ElementAccumulator(0.f)});

  Gemm gemm_op;

  cutlass::Status status;

  // Verify that GEMM operation with given arguments can be performed
  // by CUTLASS.
  status = gemm_op.can_implement(arguments);
  CUTLASS_STATUS_CHECK(status);

  // Allocate workspace for CUTLASS mixed datatypes GEMM kernel.
  const auto workspace_size = Gemm::get_workspace_size(arguments);
  auto workspace = input.new_empty({(int64_t)workspace_size},
                                  at::TensorOptions().dtype(at::kByte));

  // Initialize CUTLASS mixed datatypes GEMM object.
  status = gemm_op.initialize(arguments, workspace.data_ptr(),
                              at::cuda::getCurrentCUDAStream());
  CUTLASS_STATUS_CHECK(status);

  // Perform mixed datatypes GEMM operation.
  status = gemm_op.run(at::cuda::getCurrentCUDAStream());
  CUTLASS_STATUS_CHECK(status);

  C10_CUDA_KERNEL_LAUNCH_CHECK();

  return output;
}
#endif

Tensor
_fp16_uint8_mm(const Tensor& input, const Tensor& weight, const Tensor& scale,
               const Tensor& bias) {
#ifndef USE_ROCM
  // For now, only CC 8.x devices are supported.
  const auto dprops = at::cuda::getCurrentDeviceProperties();
  const auto is_sm8x = dprops->major == 8;
  TORCH_CHECK(is_sm8x,
              "_fp16_uint8_mm: Supported only on GPUs with compute capability "
              "8.x");

  // Validate datatypes of input tensors.
  TORCH_CHECK(input.dtype() == at::kHalf ||
              input.dtype() == at::kBFloat16,
              "_fp16_uint8_mm: The input datatype ", input.dtype(),
              " is not supported");
  TORCH_CHECK(weight.dtype() == at::kByte,
              "_fp16_uint8_mm: The weight datatype ", weight.dtype(),
              " is not supported");
  TORCH_CHECK(scale.dtype() == input.dtype(),
              "_fp16_uint8_mm: Expected scale datatype ", input.dtype(),
              " but got", scale.dtype());
  TORCH_CHECK(bias.dtype() == input.dtype(),
              "_fp16_uint8_mm: Expected bias datatype ", input.dtype(),
              " but got", bias.dtype());

  // Squash the batch dimensions of the input tensor with its
  // next-to-last dimensions.
  const auto input_sizes = input.sizes().vec();
  const auto input_2d = input.reshape({-1, input_sizes.back()});

  // Validate layouts of input tensors.
  TORCH_CHECK(input_2d.layout() == Layout::Strided,
              "_fp16_uint8_mm: Expected input argument to be strided, but got "
              "layout ", input_2d.layout());
  TORCH_CHECK(input_2d.dim() == 2,
              "_fp16_uint8_mm: Expected input argument to be 2D tensor, got ",
              input_2d.dim(), " dims");
  const auto strides_input = input_2d.strides();
  TORCH_CHECK(strides_input[0] > 1 && strides_input[1] == 1,
              "_fp16_uint8_mm: Invalid strides for input argument: row "
              "stride = ", strides_input[0], ", column stride = ",
              strides_input[1]);
  TORCH_CHECK(weight.layout() == Layout::Strided,
              "_fp16_uint8_mm: Expected inpu argument to be strided, but got "
              "layout ", weight.layout());
  TORCH_CHECK(weight.dim() == 2,
              "_fp16_uint8_mm: Expected weight argument to be 2D tensor, got ",
              weight.dim(), " dims");
  const auto strides_weight = weight.strides();
  TORCH_CHECK(strides_weight[0] > 1 && strides_weight[1] == 1,
              "_fp16_uint8_mm: Invalid strides for weight argument: row "
              "stride = ", strides_weight[0], ", column stride = ",
              strides_weight[1]);
  TORCH_CHECK(scale.dim() == 1,
              "_fp16_uint8_mm: Expected scale argument to be 1D tensor, got ",
              scale.dim(), " dims");
  TORCH_CHECK(bias.dim() == 1,
              "_fp16_uint8_mm: Expected bias argument to be 1D tensor, got ",
              bias.dim(), " dims");

  // Validate sizes of input tensors.
  TORCH_CHECK(input_2d.size(1) == weight.size(0),
              "_fp16_uint8_mm: Expected input argument to have ",
              weight.size(0), " columns, but got ", input_2d.size(1));
  TORCH_CHECK(scale.size(0) == weight.size(1),
              "_fp16_uint8_mm: Expected scale argument to have ",
              weight.size(1), " elements, but got ", scale.size(0));
  if (bias.numel() != 0) {
      TORCH_CHECK(bias.size(0) == weight.size(1),
                  "_fp16_uint8_mm: Expected bias argument to have ",
                  weight.size(1), " elements, but got ", bias.size(0));
  }


  Tensor output;
  AT_DISPATCH_SWITCH(
      input.scalar_type(),
      "_fp16_uint8_mm",
      AT_DISPATCH_CASE(
          at::ScalarType::Half,
          [&]() {
            output = mixed_dtypes_mm_dispatch_dtype<cutlass::half_t>(
                input_2d, weight, scale, bias);
            return;
          })
      AT_DISPATCH_CASE(
          at::ScalarType::BFloat16,
          [&]() {
            output = mixed_dtypes_mm_dispatch_dtype<cutlass::bfloat16_t>(
                input_2d, weight, scale, bias);
            return;
          }));

  auto output_sizes = input_sizes;
  output_sizes.back() = weight.size(1);
  return output.reshape(output_sizes);
#else
  AT_ERROR("_fp16_uint8_mm: ROCm doesn't support CUTLASS");
  return Tensor{};
#endif
}

}  // namespace native
}  // namespace at
