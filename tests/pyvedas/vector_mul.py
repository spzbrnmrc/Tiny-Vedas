"""PyVedas smoke test: 1-D elementwise multiply (aten.mul.Tensor)."""

import torch


class VectorMul(torch.nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return x * y


MODEL = torch.compile(VectorMul())
TRACE_INPUTS = (
    torch.tensor([1, 2, 3, 4], dtype=torch.int32),
    torch.tensor([2, 3, 4, 5], dtype=torch.int32),
)
