/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Word memcpy for DRAM stub ↔ DCCM slabs. STREAM callers pass
 * ``m * sizeof(int32_t)``; a byte walk at -O0 is not the ABI.
 */

#include "pyvedas.h"

void pyvedas_memcpy(void *dst, const void *src, size_t n) {
    const int32_t *s = (const int32_t *)src;
    int32_t *d = (int32_t *)dst;
    size_t words = n / sizeof(int32_t);
    size_t i;
    for (i = 0; i < words; i++) {
        d[i] = s[i];
    }
}
