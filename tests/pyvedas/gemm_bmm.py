"""PyVedas: batched 4x8x8 gemm_mmio (bmm)."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


def _batch_a() -> torch.Tensor:
    i = torch.arange(4, dtype=torch.int32).reshape(4, 1, 1)
    r = torch.arange(8, dtype=torch.int32).reshape(1, 8, 1)
    c = torch.arange(8, dtype=torch.int32).reshape(1, 1, 8)
    return ((i + r + c) % 7) - 3


MODEL = GemmMmio()
TRACE_INPUTS = (
    _batch_a(),
    torch.eye(8, dtype=torch.int32).expand(4, 8, 8).contiguous(),
)
