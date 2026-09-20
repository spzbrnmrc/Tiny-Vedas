"""PyVedas: int8 conv via im2col + GEMM (pyvedas.conv2d)."""

import torch
import torch.nn as nn

from conv_op import conv2d


class Conv2d(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        w = torch.tensor(
            [
                [[[1, 0, -1], [1, 0, -1], [1, 0, -1]]],
                [[[-1, 0, 1], [-1, 0, 1], [-1, 0, 1]]],
            ],
            dtype=torch.int32,
        )
        b = torch.tensor([0, 1], dtype=torch.int32)
        self.register_buffer("weight", w)
        self.register_buffer("bias", b)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return conv2d(x, self.weight, self.bias, 1, 1)


MODEL = Conv2d()
TRACE_INPUTS = (
    torch.tensor(
        [[
            [
                [1, 2, 3, 4],
                [0, 1, 0, 1],
                [2, 2, 1, 0],
                [1, 0, 1, 2],
            ]
        ]],
        dtype=torch.int32,
    ),
)
