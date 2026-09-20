/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Q8 exp: 256 * 2^clamp(x, -8, 8).
 */

#include "pyvedas.h"

static const int32_t k_exp_lut[17] = {
    1, 2, 4, 8, 16, 32, 64, 128, 256,
    512, 1024, 2048, 4096, 8192, 16384, 32768, 65536
};

void pyvedas_exp_i32(const int32_t *x, int32_t *out, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        int32_t v = x[i];
        if (v < -8) {
            v = -8;
        }
        if (v > 8) {
            v = 8;
        }
        out[i] = k_exp_lut[v + 8];
    }
}
