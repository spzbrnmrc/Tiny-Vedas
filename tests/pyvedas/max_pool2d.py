"""PyVedas: 2x2 stride-2 max_pool2d on int32 NCHW."""

import torch
import torch.nn as nn
import torch.nn.functional as F


class MaxPool(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.max_pool2d(x, kernel_size=2, stride=2)


MODEL = MaxPool()
TRACE_INPUTS = (
    torch.tensor(
        [[
            [
                [1, 3, 2, 0],
                [4, 2, 1, 5],
                [0, 7, 3, 1],
                [8, 1, 2, 6],
            ]
        ]],
        dtype=torch.int32,
    ),
)
