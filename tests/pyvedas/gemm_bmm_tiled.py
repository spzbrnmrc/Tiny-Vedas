"""PyVedas: 2x32x32 bmm; each slice software-tiles (forced pack budget)."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio
from jit.memory.gemm_tiles import tile_scratch_bytes


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


def _a() -> torch.Tensor:
    b = torch.arange(2, dtype=torch.int32).reshape(2, 1, 1)
    r = torch.arange(32, dtype=torch.int32).reshape(1, 32, 1)
    c = torch.arange(32, dtype=torch.int32).reshape(1, 1, 32)
    return ((b + r + c) % 7) - 3


MODEL = GemmMmio()
TRACE_INPUTS = (
    _a(),
    torch.eye(32, dtype=torch.int32).expand(2, 32, 32).contiguous(),
)
GEMM_SCRATCH_BYTES = tile_scratch_bytes(8, 8, 32, 32, 32)
