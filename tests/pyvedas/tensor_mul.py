"""PyVedas smoke test: 3-D elementwise multiply (aten.mul.Tensor)."""

import torch


class TensorMul(torch.nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return x * y


MODEL = torch.compile(TensorMul())
TRACE_INPUTS = (
    torch.tensor(
        [[[1, 2], [3, 4]], [[5, 6], [7, 8]]],
        dtype=torch.int32,
    ),
    torch.tensor(
        [[[2, 3], [4, 5]], [[6, 7], [8, 9]]],
        dtype=torch.int32,
    ),
)
