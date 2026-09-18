# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Fit-or-tile planner for GEMM jobs against on-chip pack scratch.

Hardware already micro-tiles one START (8x8 PE, K-tile 32). This helper
splits a 2-D problem only when int8 pack + optional int32 C scratch do not
fit the given byte budget. Software tiles are PE/K-aligned except remainders.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Sequence, Tuple

PE_DIM = 8
K_TILE = 32

# Match sim / Alveo DCCM (2^18 words). The compiler sizes pack scratch per tile.
DCCM_BYTES = 262144 * 4
DCCM_RESERVE_BYTES = 64 * 1024
SCRATCH_CAP_BYTES = 128 * 1024
ALIGN_PAD_BYTES = 3


@dataclass(frozen=True)
class GemmJob:
    m0: int
    n0: int
    k0: int
    m_t: int
    n_t: int
    k_t: int


def scratch_budget(
    live_bytes: int,
    *,
    dccm_bytes: int = DCCM_BYTES,
    reserve_bytes: int = DCCM_RESERVE_BYTES,
    scratch_cap: int = SCRATCH_CAP_BYTES,
) -> int:
    """Bytes left for int8 A/B pack + optional int32 C tile."""
    used = reserve_bytes + live_bytes
    left = dccm_bytes - used if dccm_bytes > used else 0
    return min(left, scratch_cap)


def live_bytes_2d(m: int, n: int, k: int) -> int:
    return 4 * (m * k + k * n + m * n)


def dim_candidates(dim: int, align: int) -> List[int]:
    """Tile sizes: PE/K multiples, plus the full dim (remainder / one-shot)."""
    if dim <= 0:
        return []
    if dim <= align:
        return [dim]
    vals = list(range(align, (dim // align) * align + 1, align))
    if dim not in vals:
        vals.append(dim)
    return vals


def tile_scratch_bytes(m_t: int, n_t: int, k_t: int, n: int, k: int) -> int:
    """Pack A/B plus C scratch when the hardware C layout is not a C strip."""
    pack = m_t * k_t + k_t * n_t
    direct = k_t == k and n_t == n
    tmp = 0 if direct else m_t * n_t * 4
    pad = 0 if direct else ALIGN_PAD_BYTES
    return pack + tmp + pad


def choose_tile(
    m: int, n: int, k: int, scratch_bytes: int
) -> Tuple[int, int, int] | None:
    """Largest (m_t, n_t, k_t) whose pack footprint fits *scratch_bytes*.

    Maximizes m_t*n_t*k_t (work per START). Ties prefer larger k_t (fewer
    software K-accumulates), then n_t, then m_t.
    """
    if m <= 0 or n <= 0 or k <= 0:
        return None
    best: Tuple[int, int, int, int] | None = None
    for k_t in dim_candidates(k, K_TILE):
        for n_t in dim_candidates(n, PE_DIM):
            for m_t in dim_candidates(m, PE_DIM):
                if tile_scratch_bytes(m_t, n_t, k_t, n, k) > scratch_bytes:
                    continue
                work = m_t * n_t * k_t
                key = (work, k_t, n_t, m_t)
                if best is None or key > best:
                    best = key
    if best is None:
        return None
    _, k_t, n_t, m_t = best
    return m_t, n_t, k_t


def plan_gemm_jobs(m: int, n: int, k: int, scratch_bytes: int) -> List[GemmJob]:
    """Expand a 2-D GEMM into START jobs, or a single one-shot job."""
    tile = choose_tile(m, n, k, scratch_bytes)
    if tile is None:
        return []
    m_t, n_t, k_t = tile
    jobs: List[GemmJob] = []
    m0 = 0
    while m0 < m:
        mti = min(m_t, m - m0)
        n0 = 0
        while n0 < n:
            nti = min(n_t, n - n0)
            k0 = 0
            while k0 < k:
                kti = min(k_t, k - k0)
                jobs.append(GemmJob(m0, n0, k0, mti, nti, kti))
                k0 += k_t
            n0 += n_t
        m0 += m_t
    return jobs


def broadcast_batch_shape(
    a_batch: Sequence[int], b_batch: Sequence[int]
) -> Tuple[int, ...]:
    rank = max(len(a_batch), len(b_batch))
    a_pad = (1,) * (rank - len(a_batch)) + tuple(a_batch)
    b_pad = (1,) * (rank - len(b_batch)) + tuple(b_batch)
    out: List[int] = []
    for da, db in zip(a_pad, b_pad):
        if da != db and da != 1 and db != 1:
            raise ValueError(f"batch dims do not broadcast: {a_batch} vs {b_batch}")
        out.append(max(da, db))
    return tuple(out)


def matmul_out_shape(
    a_shape: Sequence[int], b_shape: Sequence[int]
) -> Tuple[int, ...]:
    """Output shape of torch.matmul / numpy matmul (last two dims, broadcast rest)."""
    if len(a_shape) < 2 or len(b_shape) < 2:
        raise ValueError("matmul requires rank >= 2")
    m, k = a_shape[-2], a_shape[-1]
    k2, n = b_shape[-2], b_shape[-1]
    if k != k2:
        raise ValueError(f"inner dims differ ({k} vs {k2})")
    batch = broadcast_batch_shape(a_shape[:-2], b_shape[:-2])
    return batch + (m, n)


def numel(shape: Sequence[int]) -> int:
    n = 1
    for dim in shape:
        n *= int(dim)
    return n
