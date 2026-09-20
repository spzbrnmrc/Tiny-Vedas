/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_slice(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    size_t dim,
    size_t start,
    size_t end
) {
    size_t out_shape[8];
    size_t out_n = 1;
    int d;
    size_t i, rest, in_idx, stride;
    size_t coord[8];

    for (d = 0; d < rank; d++) {
        out_shape[d] = in_shape[d];
    }
    out_shape[dim] = (end > start) ? (end - start) : 0;
    for (d = 0; d < rank; d++) {
        out_n *= out_shape[d];
    }
    for (i = 0; i < out_n; i++) {
        rest = i;
        for (d = rank - 1; d >= 0; d--) {
            coord[d] = rest % out_shape[d];
            rest /= out_shape[d];
        }
        coord[dim] += start;
        in_idx = 0;
        stride = 1;
        for (d = rank - 1; d >= 0; d--) {
            in_idx += coord[d] * stride;
            stride *= in_shape[d];
        }
        out[i] = in[in_idx];
    }
}
