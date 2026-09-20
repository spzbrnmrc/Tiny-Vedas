/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_cat(
    const int32_t **ins,
    const size_t *dim_sizes,
    int32_t *out,
    size_t n,
    size_t outer,
    size_t inner
) {
    size_t o, t, j, i, off, out_dim, src;

    out_dim = 0;
    for (t = 0; t < n; t++) {
        out_dim += dim_sizes[t];
    }
    for (o = 0; o < outer; o++) {
        off = 0;
        for (t = 0; t < n; t++) {
            for (j = 0; j < dim_sizes[t]; j++) {
                src = (o * dim_sizes[t] + j) * inner;
                for (i = 0; i < inner; i++) {
                    out[(o * out_dim + off + j) * inner + i] = ins[t][src + i];
                }
            }
            off += dim_sizes[t];
        }
    }
}
