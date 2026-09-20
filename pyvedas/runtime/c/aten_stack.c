/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_stack(
    const int32_t **ins,
    int32_t *out,
    size_t n,
    size_t outer,
    size_t inner
) {
    size_t o, t, i;
    for (o = 0; o < outer; o++) {
        for (t = 0; t < n; t++) {
            for (i = 0; i < inner; i++) {
                out[(o * n + t) * inner + i] = ins[t][o * inner + i];
            }
        }
    }
}
