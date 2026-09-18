"""PyVedas: 512x8x257 gemm_mmio (exceeds the old 256^2 whole-matrix pack)."""

import torch
import torch.nn as nn

from gemm_op import gemm_mmio


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


def _mat(rows: int, cols: int, seed: int) -> torch.Tensor:
    i = torch.arange(rows, dtype=torch.int32).unsqueeze(1)
    j = torch.arange(cols, dtype=torch.int32).unsqueeze(0)
    return ((i * 3 + j + seed) % 7) - 3


MODEL = GemmMmio()
TRACE_INPUTS = (_mat(512, 257, 1), _mat(257, 8, 2))
