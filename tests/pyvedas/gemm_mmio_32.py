"""PyVedas: 32x32 gemm_mmio (one START; hardware micro-tiles)."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


def _a() -> torch.Tensor:
    i = torch.arange(32, dtype=torch.int32).unsqueeze(1)
    j = torch.arange(32, dtype=torch.int32).unsqueeze(0)
    return ((i + j) % 7) - 3


MODEL = GemmMmio()
TRACE_INPUTS = (_a(), torch.eye(32, dtype=torch.int32))
