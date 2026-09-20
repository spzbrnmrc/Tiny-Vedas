"""PyVedas: integer sigmoid + exp."""

import torch
import torch.nn as nn

from int_ops import exp_i32, sigmoid_i32


class SigExp(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return sigmoid_i32(x) + exp_i32(x)


MODEL = SigExp()
TRACE_INPUTS = (
    torch.tensor([-8, -1, 0, 1, 8], dtype=torch.int32),
)
