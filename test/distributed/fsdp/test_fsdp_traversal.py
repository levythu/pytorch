# Owner(s): ["oncall: distributed"]

import sys

from torch import distributed as dist
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP
from torch.testing._internal.common_distributed import skip_if_lt_x_gpu
from torch.testing._internal.common_fsdp import (
    CUDAInitMode,
    FSDPInitMode,
    FSDPTestMultiThread,
    NestedWrappedModule,
)
from torch.testing._internal.common_utils import run_tests, TEST_WITH_DEV_DBG_ASAN

if not dist.is_available():
    print("Distributed not available, skipping tests", file=sys.stderr)
    sys.exit(0)

if TEST_WITH_DEV_DBG_ASAN:
    print(
        "Skip dev-asan as torch + multiprocessing spawn have known issues",
        file=sys.stderr,
    )
    sys.exit(0)


class TestTraversal(FSDPTestMultiThread):
    @property
    def world_size(self):
        return 2

    @property
    def process_group(self):
        return dist.distributed_c10d._get_default_group()

    @skip_if_lt_x_gpu(2)
    def test_fsdp_modules(self):
        nested_wrapped_module = NestedWrappedModule.init(
            self.process_group,
            FSDPInitMode.RECURSIVE,
            CUDAInitMode.CUDA_BEFORE,
        )
        modules = FSDP.fsdp_modules(nested_wrapped_module)
        self.assertEqual(
            modules,
            [
                nested_wrapped_module.module.get_submodule("1"),
                nested_wrapped_module.module.get_submodule("1").get_submodule("0"),
                nested_wrapped_module.module.get_submodule("2"),
            ],
        )
        modules = FSDP.fsdp_modules(nested_wrapped_module, root_only=True)
        self.assertEqual(
            modules,
            [
                nested_wrapped_module.module.get_submodule("1"),
                nested_wrapped_module.module.get_submodule("2"),
            ],
        )


if __name__ == "__main__":
    run_tests()
