"""PyVedas skeleton: gemm_mmio CSR sequence (int8 A/B, int32 C)."""

import torch
import torch.nn as nn


@torch.library.custom_op("pyvedas::gemm_mmio", mutates_args=())
def gemm_mmio(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """Eager golden: C = A @ B with int8 values held in int32 tensors."""
    return (a.to(torch.int32) @ b.to(torch.int32)).to(torch.int32)


@gemm_mmio.register_fake
def _(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    return torch.empty(
        a.shape[0], b.shape[1], dtype=torch.int32, device=a.device
    )


class GemmMmio(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return gemm_mmio(x, y)


MODEL = GemmMmio()
TRACE_INPUTS = (
    torch.tensor(
        [[1, 2, 3, 4, 5, 6, 7, 8]] * 8,
        dtype=torch.int32,
    ),
    torch.eye(8, dtype=torch.int32),
)
