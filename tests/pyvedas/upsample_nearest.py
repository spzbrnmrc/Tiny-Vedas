"""PyVedas: integer nearest upsample."""

import torch
import torch.nn as nn

from int_ops import upsample_nearest


class Up(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return upsample_nearest(x, 4, 4)


MODEL = Up()
TRACE_INPUTS = (
    torch.tensor([[[[1, 2], [3, 4]]]], dtype=torch.int32),
)
