"""PyVedas: aten.cat along channels."""

import torch
import torch.nn as nn


class Cat(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return torch.cat((x, y), dim=1)


MODEL = Cat()
TRACE_INPUTS = (
    torch.ones(1, 2, 2, 2, dtype=torch.int32),
    torch.full((1, 1, 2, 2), 3, dtype=torch.int32),
)
