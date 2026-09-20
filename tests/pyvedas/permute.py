"""PyVedas: permute NCHW -> NHWC-style."""

import torch
import torch.nn as nn


class Permute(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x.permute(0, 2, 3, 1).contiguous()


MODEL = Permute()
TRACE_INPUTS = (
    torch.tensor([[[[1, 2], [3, 4]]]], dtype=torch.int32),
)
