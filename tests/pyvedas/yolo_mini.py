"""PyVedas mini YOLO-shaped graph: get_attr conv, leaky, pool, two outputs."""

import torch
import torch.nn as nn
import torch.nn.functional as F

from conv_op import conv2d
from int_ops import leaky_relu


class MiniYolo(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        w0 = torch.ones(2, 1, 3, 3, dtype=torch.int32)
        b0 = torch.zeros(2, dtype=torch.int32)
        w1 = torch.ones(1, 2, 1, 1, dtype=torch.int32)
        b1 = torch.tensor([2], dtype=torch.int32)
        self.register_buffer("w0", w0)
        self.register_buffer("b0", b0)
        self.register_buffer("w1", w1)
        self.register_buffer("b1", b1)

    def forward(self, x: torch.Tensor):
        y = leaky_relu(conv2d(x, self.w0, self.b0, 1, 1))
        pooled = F.max_pool2d(y, kernel_size=2, stride=2)
        det = conv2d(pooled, self.w1, self.b1, 1, 0)
        return pooled, det


MODEL = MiniYolo()
TRACE_INPUTS = (
    torch.tensor(
        [[
            [
                [1, 0, -2, 3],
                [0, 1, 0, -1],
                [2, -3, 1, 0],
                [1, 1, -1, 2],
            ]
        ]],
        dtype=torch.int32,
    ),
)
