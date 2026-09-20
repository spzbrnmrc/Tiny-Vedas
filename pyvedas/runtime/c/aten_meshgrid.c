/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_meshgrid(
    const int32_t *a,
    const int32_t *b,
    int32_t *gy,
    int32_t *gx,
    size_t h,
    size_t w
) {
    size_t y, x;
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            gy[y * w + x] = a[y];
            gx[y * w + x] = b[x];
        }
    }
}
