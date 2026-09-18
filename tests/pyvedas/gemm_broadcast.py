"""PyVedas: broadcast batch (3,1,8,8) @ (8,8) gemm_mmio."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


def _a() -> torch.Tensor:
    b = torch.arange(3, dtype=torch.int32).reshape(3, 1, 1, 1)
    r = torch.arange(8, dtype=torch.int32).reshape(1, 1, 8, 1)
    c = torch.arange(8, dtype=torch.int32).reshape(1, 1, 1, 8)
    return ((b + r + c) % 7) - 3


MODEL = GemmMmio()
TRACE_INPUTS = (_a(), torch.eye(8, dtype=torch.int32))
