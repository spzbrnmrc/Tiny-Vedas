"""PyVedas: integer leaky ReLU (x>=0 ? x : x/10)."""

import torch
import torch.nn as nn

from int_ops import leaky_relu


class Leaky(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return leaky_relu(x)


MODEL = Leaky()
TRACE_INPUTS = (
    torch.tensor(
        [[[[-20, -10, -1, 0], [1, 5, 10, 30]]]],
        dtype=torch.int32,
    ),
)
