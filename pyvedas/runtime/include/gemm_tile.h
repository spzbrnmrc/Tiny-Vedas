/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fit-or-tile planner for one 2-D GEMM against pack-scratch bytes.
 * Keep in lockstep with pyvedas/jit/memory/gemm_tiles.py.
 */

#ifndef PYVEDAS_GEMM_TILE_H
#define PYVEDAS_GEMM_TILE_H

#include <stddef.h>
#include <stdint.h>

#ifndef PYVEDAS_GEMM_PE_DIM
#define PYVEDAS_GEMM_PE_DIM 8
#endif
#ifndef PYVEDAS_GEMM_K_TILE
#define PYVEDAS_GEMM_K_TILE 32
#endif
#ifndef PYVEDAS_DCCM_BYTES
#define PYVEDAS_DCCM_BYTES (262144u * 4u)
#endif
#ifndef PYVEDAS_DCCM_RESERVE_BYTES
#define PYVEDAS_DCCM_RESERVE_BYTES (64u * 1024u)
#endif
#ifndef PYVEDAS_GEMM_SCRATCH_BYTES
#define PYVEDAS_GEMM_SCRATCH_BYTES (128u * 1024u)
#endif
#define PYVEDAS_GEMM_ALIGN_PAD 3u
#define PYVEDAS_GEMM_MAX_RANK 8

typedef struct {
    uint32_t m0;
    uint32_t n0;
    uint32_t k0;
    uint32_t m_t;
    uint32_t n_t;
    uint32_t k_t;
} pyvedas_gemm_job_t;

size_t pyvedas_gemm_scratch_budget(size_t live_bytes);

void pyvedas_gemm_set_scratch_cap(size_t bytes);

int pyvedas_gemm_choose_tile(
    size_t m,
    size_t n,
    size_t k,
    size_t scratch_bytes,
    size_t *m_t,
    size_t *n_t,
    size_t *k_t
);

/* Write up to jobs_cap jobs. Returns the full job count (0 if no tile fits). */
size_t pyvedas_gemm_plan(
    size_t m,
    size_t n,
    size_t k,
    size_t scratch_bytes,
    pyvedas_gemm_job_t *jobs,
    size_t jobs_cap
);

#endif
