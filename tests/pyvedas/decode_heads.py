"""PyVedas: compact integer decode-shaped graph (slice, meshgrid, stack, cat)."""

import torch
import torch.nn as nn

from int_ops import exp_i32, sigmoid_i32


class TinyDecode(nn.Module):
    def forward(self, pred: torch.Tensor) -> torch.Tensor:
        # (1, 6, 2, 2) -> (1, 2, 3, 2, 2) -> (1, 2, 2, 2, 3)
        x = pred.view(1, 2, 3, 2, 2)
        x = x.permute(0, 1, 3, 4, 2).contiguous()
        xy = sigmoid_i32(x[..., 0:2])
        wh = exp_i32(x[..., 2:3])
        gy, gx = torch.meshgrid(
            torch.arange(2, dtype=torch.int32),
            torch.arange(2, dtype=torch.int32),
            indexing="ij",
        )
        grid = torch.stack((gx, gy), dim=-1)
        q8 = torch.tensor(256, dtype=torch.int32)
        xy_px = torch.div((xy + grid * q8) * 16, q8, rounding_mode="trunc")
        return torch.cat((xy_px, wh), dim=-1)


MODEL = TinyDecode()
TRACE_INPUTS = (
    torch.randint(-4, 5, (1, 6, 2, 2), dtype=torch.int32),
)
