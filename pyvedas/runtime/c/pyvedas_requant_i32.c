/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * y = clamp((x * mul) >> shift, -127, 127)
 */

#include "pyvedas.h"

void pyvedas_requant_i32(
    const int32_t *x,
    int32_t *out,
    size_t n,
    int32_t mul,
    int32_t shift
) {
    size_t i;
    for (i = 0; i < n; i++) {
        int64_t v = (int64_t)x[i] * (int64_t)mul;
        if (shift > 0) {
            v >>= shift;
        }
        if (v > 127) {
            v = 127;
        }
        if (v < -127) {
            v = -127;
        }
        out[i] = (int32_t)v;
    }
}
