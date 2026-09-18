# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""GraphModule custom op: int8 GEMM via Tiny-Vedas MMIO (int32 containers)."""

from __future__ import annotations

import torch

from jit.memory.gemm_tiles import matmul_out_shape


@torch.library.custom_op("pyvedas::gemm_mmio", mutates_args=())
def gemm_mmio(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """Eager golden: C = A @ B with int8 values held in int32 tensors."""
    return torch.matmul(a.to(torch.int32), b.to(torch.int32)).to(torch.int32)


@gemm_mmio.register_fake
def _(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    shape = matmul_out_shape(tuple(a.shape), tuple(b.shape))
    return torch.empty(*shape, dtype=torch.int32, device=a.device)
