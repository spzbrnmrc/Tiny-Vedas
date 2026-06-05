"""PyVedas smoke test: 3-D tensor add (aten.add.Tensor)."""

import torch


class TensorAdd(torch.nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return x + y


MODEL = torch.compile(TensorAdd())
TRACE_INPUTS = (
    torch.tensor(
        [[[1, 2], [3, 4]], [[5, 6], [7, 8]]],
        dtype=torch.int32,
    ),
    torch.tensor(
        [[[10, 20], [30, 40]], [[50, 60], [70, 80]]],
        dtype=torch.int32,
    ),
)
