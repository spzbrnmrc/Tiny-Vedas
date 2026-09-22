"""Integer requant: y = clamp((x * mul) >> shift, -127, 127)."""

import torch
import torch.nn as nn

from int_ops import requant_i32


class Requant(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return requant_i32(x, 3, 2)


MODEL = Requant()
TRACE_INPUTS = (
    torch.tensor(
        [[[[-200, -40, -1, 0], [1, 40, 80, 400]]]],
        dtype=torch.int32,
    ),
)
