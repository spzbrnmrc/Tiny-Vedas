/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_permute(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    const int *dims
) {
    size_t out_shape[8];
    size_t in_stride[8];
    size_t out_n = 1;
    int d;
    size_t i, rest, in_idx;
    size_t coord[8];

    in_stride[rank - 1] = 1;
    for (d = rank - 2; d >= 0; d--) {
        in_stride[d] = in_stride[d + 1] * in_shape[d + 1];
    }
    for (d = 0; d < rank; d++) {
        out_shape[d] = in_shape[dims[d]];
        out_n *= out_shape[d];
    }
    for (i = 0; i < out_n; i++) {
        rest = i;
        for (d = rank - 1; d >= 0; d--) {
            coord[d] = rest % out_shape[d];
            rest /= out_shape[d];
        }
        in_idx = 0;
        for (d = 0; d < rank; d++) {
            in_idx += coord[d] * in_stride[dims[d]];
        }
        out[i] = in[in_idx];
    }
}
