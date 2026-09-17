/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"
#include "soc_defines.h"
#include "gemm_csrs.h"

/* GraphModule op: gemm_mmio
 * Pack int32 A/B (values in signed int8 range) and kick the GEMM CSRs.
 * START stalls the core until C is written; no status poll. */
void pyvedas_gemm_mmio(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t m,
    size_t n,
    size_t k
) {
    volatile unsigned *csr = (volatile unsigned *)MMIO_GEMM_ADDR;
    enum { GEMM_MAX_ELEMS = 256 * 256 };
    static int8_t a8[GEMM_MAX_ELEMS];
    static int8_t b8[GEMM_MAX_ELEMS];
    size_t i;

    if (m * k > GEMM_MAX_ELEMS || k * n > GEMM_MAX_ELEMS) {
        for (;;)
            ;
    }

    for (i = 0; i < m * k; i++) {
        a8[i] = (int8_t)a[i];
    }
    for (i = 0; i < k * n; i++) {
        b8[i] = (int8_t)b[i];
    }

    csr[GEMM_OFF_BASE_A / 4] = (unsigned)(uintptr_t)a8;
    csr[GEMM_OFF_BASE_B / 4] = (unsigned)(uintptr_t)b8;
    csr[GEMM_OFF_BASE_C / 4] = (unsigned)(uintptr_t)out;
    csr[GEMM_OFF_M / 4]      = (unsigned)m;
    csr[GEMM_OFF_N / 4]      = (unsigned)n;
    csr[GEMM_OFF_K / 4]      = (unsigned)k;
    csr[GEMM_OFF_CTRL / 4]   = GEMM_CTRL_START;
}
