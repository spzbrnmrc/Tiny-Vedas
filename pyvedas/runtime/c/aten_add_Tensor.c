/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

/* GraphModule op: aten.add.Tensor
 * Flat elementwise add over two vectors of length n (row-major source layout).
 * Will be replaced with hardware vector support when available. */
void pyvedas_aten_add_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
) {
    for (size_t i = 0; i < n; i++) {
        out[i] = a[i] + b[i];
    }
}
