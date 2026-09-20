/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_pad(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    const size_t *out_shape,
    int n_pad,
    const int *pad,
    int32_t value
) {
    size_t out_n = 1;
    size_t in_n = 1;
    int d;
    size_t i;
    size_t coord[8];
    int ndims = n_pad / 2;

    for (d = 0; d < rank; d++) {
        out_n *= out_shape[d];
        in_n *= in_shape[d];
    }
    (void)in_n;

    for (i = 0; i < out_n; i++) {
        size_t rest = i;
        int inside = 1;
        size_t in_idx = 0;
        size_t in_stride = 1;
        int dim;

        for (d = rank - 1; d >= 0; d--) {
            coord[d] = rest % out_shape[d];
            rest /= out_shape[d];
        }
        /* F.pad: pad[0],pad[1] apply to last dim, then previous. */
        for (dim = 0; dim < rank; dim++) {
            int from_end = rank - 1 - dim;
            long src = (long)coord[dim];
            if (from_end < ndims) {
                src -= (long)pad[2 * from_end];
            }
            if (src < 0 || src >= (long)in_shape[dim]) {
                inside = 0;
                break;
            }
            coord[dim] = (size_t)src;
        }
        if (!inside) {
            out[i] = value;
            continue;
        }
        in_idx = 0;
        in_stride = 1;
        for (d = rank - 1; d >= 0; d--) {
            in_idx += coord[d] * in_stride;
            in_stride *= in_shape[d];
        }
        out[i] = in[in_idx];
    }
}
