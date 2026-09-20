/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Q8 piecewise logistic: 128 + 16*x, clamp [0, 256].
 */

#include "pyvedas.h"

void pyvedas_sigmoid_i32(const int32_t *x, int32_t *out, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        int32_t y = 128 + x[i] * 16;
        if (y < 0) {
            y = 0;
        }
        if (y > 256) {
            y = 256;
        }
        out[i] = y;
    }
}
