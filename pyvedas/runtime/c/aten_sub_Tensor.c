/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_sub_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
) {
    size_t i;
    for (i = 0; i < n; i++) {
        out[i] = a[i] - b[i];
    }
}
