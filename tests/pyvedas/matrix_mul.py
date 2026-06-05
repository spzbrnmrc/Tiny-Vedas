"""PyVedas smoke test: 2-D elementwise multiply (aten.mul.Tensor)."""

import torch


class MatrixMul(torch.nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return x * y


MODEL = torch.compile(MatrixMul())
TRACE_INPUTS = (
    torch.tensor([[1, 2], [3, 4]], dtype=torch.int32),
    torch.tensor([[2, 3], [4, 5]], dtype=torch.int32),
)
