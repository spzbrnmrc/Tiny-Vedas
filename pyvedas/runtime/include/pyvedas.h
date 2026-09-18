/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef PYVEDAS_H
#define PYVEDAS_H

#include <stddef.h>
#include <stdint.h>

/* Host and bare-metal callable runtime ("our CUDA").
 *
 * Each function implements one GraphModule op (1:1 with runtime/ops.yaml).
 * Signatures use flat vectors only — there are no tensors at runtime, just
 * (pointer, numel) buffers. Rank, batch, and GEMM tile sizes are compile-time
 * in generated.c. This entry runs one already-planned hardware job.
 */

void pyvedas_aten_add_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_aten_mul_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_gemm_job(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t m,
    size_t n,
    size_t k,
    size_t m0,
    size_t n0,
    size_t k0,
    size_t m_t,
    size_t n_t,
    size_t k_t,
    uint8_t *scratch
);

#endif
