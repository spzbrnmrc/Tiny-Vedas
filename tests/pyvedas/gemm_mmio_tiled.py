"""PyVedas: 32x32 gemm_mmio software-tiled via a PE-sized pack budget."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio
from jit.memory.gemm_tiles import tile_scratch_bytes


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


def _a() -> torch.Tensor:
    i = torch.arange(32, dtype=torch.int32).unsqueeze(1)
    j = torch.arange(32, dtype=torch.int32).unsqueeze(0)
    return ((i + j) % 7) - 3


MODEL = GemmMmio()
TRACE_INPUTS = (_a(), torch.eye(32, dtype=torch.int32))
GEMM_SCRATCH_BYTES = tile_scratch_bytes(8, 8, 32, 32, 32)
