"""PyVedas: 8x8 gemm_mmio (one START; hardware micro-tiles)."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


MODEL = GemmMmio()
TRACE_INPUTS = (
    torch.tensor(
        [[1, 2, 3, 4, 5, 6, 7, 8]] * 8,
        dtype=torch.int32,
    ),
    torch.eye(8, dtype=torch.int32),
)
