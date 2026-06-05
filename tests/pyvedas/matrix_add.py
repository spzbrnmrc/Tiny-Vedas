"""PyVedas smoke test: 2-D tensor add (aten.add.Tensor)."""

import torch


class MatrixAdd(torch.nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return x + y


MODEL = torch.compile(MatrixAdd())
TRACE_INPUTS = (
    torch.tensor([[1, 2], [3, 4]], dtype=torch.int32),
    torch.tensor([[10, 20], [30, 40]], dtype=torch.int32),
)
