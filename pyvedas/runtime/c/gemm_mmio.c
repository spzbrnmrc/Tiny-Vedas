/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * One compiler-planned GEMM job: pack a tile, START, scatter/add C.
 * Tile sizes and the walk over M/N/K/batch are emitted in generated.c.
 */

#include "pyvedas.h"
#include "soc_defines.h"
#include "gemm_csrs.h"

#include <stdint.h>

static void gemm_start(
    const int8_t *a,
    const int8_t *b,
    int32_t *c,
    unsigned m,
    unsigned n,
    unsigned k
) {
    volatile unsigned *csr = (volatile unsigned *)MMIO_GEMM_ADDR;

    csr[GEMM_OFF_BASE_A / 4] = (unsigned)(uintptr_t)a;
    csr[GEMM_OFF_BASE_B / 4] = (unsigned)(uintptr_t)b;
    csr[GEMM_OFF_BASE_C / 4] = (unsigned)(uintptr_t)c;
    csr[GEMM_OFF_M / 4]      = m;
    csr[GEMM_OFF_N / 4]      = n;
    csr[GEMM_OFF_K / 4]      = k;
    csr[GEMM_OFF_CTRL / 4]   = GEMM_CTRL_START;
}

static void pack_a(
    int8_t *a8,
    const int32_t *a,
    size_t m0,
    size_t k0,
    size_t m_t,
    size_t k_t,
    size_t k
) {
    size_t i, t;
    for (i = 0; i < m_t; i++) {
        for (t = 0; t < k_t; t++) {
            a8[i * k_t + t] = (int8_t)a[(m0 + i) * k + (k0 + t)];
        }
    }
}

static void pack_b(
    int8_t *b8,
    const int32_t *b,
    size_t n0,
    size_t k0,
    size_t n_t,
    size_t k_t,
    size_t n
) {
    size_t t, j;
    for (t = 0; t < k_t; t++) {
        for (j = 0; j < n_t; j++) {
            b8[t * n_t + j] = (int8_t)b[(k0 + t) * n + (n0 + j)];
        }
    }
}

static void scatter_c(
    int32_t *out,
    const int32_t *tmp,
    size_t m0,
    size_t n0,
    size_t m_t,
    size_t n_t,
    size_t n,
    int add
) {
    size_t i, j;
    for (i = 0; i < m_t; i++) {
        for (j = 0; j < n_t; j++) {
            size_t dst = (m0 + i) * n + (n0 + j);
            if (add) {
                out[dst] += tmp[i * n_t + j];
            } else {
                out[dst] = tmp[i * n_t + j];
            }
        }
    }
}

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
) {
    int8_t *a8;
    int8_t *b8;
    uintptr_t tmp_addr;
    int32_t *tmp;

    if (m_t == 0 || n_t == 0 || k_t == 0) {
        return;
    }

    a8 = (int8_t *)scratch;
    b8 = a8 + m_t * k_t;
    tmp_addr = ((uintptr_t)(b8 + k_t * n_t) + 3u) & ~(uintptr_t)3u;
    tmp = (int32_t *)tmp_addr;

    pack_a(a8, a, m0, k0, m_t, k_t, k);
    pack_b(b8, b, n0, k0, n_t, k_t, n);

    /* Full-width first K panel: hardware C stride is n_t, matching C[m0:, :]. */
    if (n_t == n && k0 == 0) {
        gemm_start(a8, b8, &out[m0 * n], (unsigned)m_t, (unsigned)n_t, (unsigned)k_t);
    } else {
        gemm_start(a8, b8, tmp, (unsigned)m_t, (unsigned)n_t, (unsigned)k_t);
        scatter_c(out, tmp, m0, n0, m_t, n_t, n, k0 != 0);
    }
}
