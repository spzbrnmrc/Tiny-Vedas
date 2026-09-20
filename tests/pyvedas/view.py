"""PyVedas: view / reshape alias."""

import torch
import torch.nn as nn


class View(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x.view(1, -1)


MODEL = View()
TRACE_INPUTS = (
    torch.tensor([[[[1, 2], [3, 4]]]], dtype=torch.int32),
)
