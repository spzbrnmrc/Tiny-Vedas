"""PyVedas: integer bilinear upsample."""

import torch
import torch.nn as nn

from int_ops import upsample_bilinear


class UpBilinear(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return upsample_bilinear(x, 4, 4)


MODEL = UpBilinear()
TRACE_INPUTS = (
    torch.tensor([[[[10, 20], [30, 40]]]], dtype=torch.int32),
)
