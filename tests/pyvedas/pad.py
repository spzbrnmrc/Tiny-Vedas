"""PyVedas: constant pad (MaxPoolSame-style)."""

import torch
import torch.nn as nn
import torch.nn.functional as F


class Pad(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.pad(x, (0, 1, 0, 1))


MODEL = Pad()
TRACE_INPUTS = (
    torch.tensor([[[[1, 2], [3, 4]]]], dtype=torch.int32),
)
