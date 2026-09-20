/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_select(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    size_t dim,
    size_t index
) {
    size_t out_shape[8];
    size_t out_coord[8];
    size_t coord_in[8];
    size_t out_rank = 0;
    size_t out_n = 1;
    size_t i, rest, in_idx, stride;
    int d;
    size_t od;

    for (d = 0; d < rank; d++) {
        if ((size_t)d == dim) {
            continue;
        }
        out_shape[out_rank++] = in_shape[d];
    }
    for (od = 0; od < out_rank; od++) {
        out_n *= out_shape[od];
    }
    for (i = 0; i < out_n; i++) {
        rest = i;
        for (d = (int)out_rank - 1; d >= 0; d--) {
            out_coord[d] = rest % out_shape[d];
            rest /= out_shape[d];
        }
        od = 0;
        for (d = 0; d < rank; d++) {
            if ((size_t)d == dim) {
                coord_in[d] = index;
            } else {
                coord_in[d] = out_coord[od++];
            }
        }
        in_idx = 0;
        stride = 1;
        for (d = rank - 1; d >= 0; d--) {
            in_idx += coord_in[d] * stride;
            stride *= in_shape[d];
        }
        out[i] = in[in_idx];
    }
}
