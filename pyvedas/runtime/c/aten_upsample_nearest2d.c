/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_upsample_nearest(
    const int32_t *in,
    int32_t *out,
    size_t n,
    size_t c,
    size_t ih,
    size_t iw,
    size_t oh,
    size_t ow
) {
    size_t ni, ci, oy, ox, iy, ix;
    for (ni = 0; ni < n; ni++) {
        for (ci = 0; ci < c; ci++) {
            for (oy = 0; oy < oh; oy++) {
                iy = (oy * ih) / oh;
                if (iy >= ih) {
                    iy = ih - 1;
                }
                for (ox = 0; ox < ow; ox++) {
                    ix = (ox * iw) / ow;
                    if (ix >= iw) {
                        ix = iw - 1;
                    }
                    out[((ni * c + ci) * oh + oy) * ow + ox] =
                        in[((ni * c + ci) * ih + iy) * iw + ix];
                }
            }
        }
    }
}
