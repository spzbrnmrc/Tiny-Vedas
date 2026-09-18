# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Signed int8 GEMM reference: C = A @ B, row-major, int32 accumulate."""

from __future__ import annotations

from typing import List, Sequence


def s8(value: int) -> int:
    v = value & 0xFF
    return v - 256 if v >= 128 else v


def gemm_int8(
    a: Sequence[int],
    b: Sequence[int],
    m: int,
    n: int,
    k: int,
) -> List[int]:
    """Flattened row-major A[m*k], B[k*n] -> C[m*n] int32."""
    c = [0] * (m * n)
    for i in range(m):
        for j in range(n):
            acc = 0
            for t in range(k):
                acc += s8(a[i * k + t]) * s8(b[t * n + j])
            c[i * n + j] = acc & 0xFFFFFFFF
            if c[i * n + j] >= 0x80000000:
                c[i * n + j] -= 0x100000000
    return c
