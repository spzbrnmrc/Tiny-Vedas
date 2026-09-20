/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Integer bilinear, align_corners=False, Q16 weights. Matches pyvedas/int_ops.py.
 */

#include "pyvedas.h"

static int src_coord_q16(int o, int out_s, int in_s) {
    return ((2 * o + 1) * in_s * 65536) / (2 * out_s) - 32768;
}

void pyvedas_upsample_bilinear(
    const int32_t *in,
    int32_t *out,
    size_t n,
    size_t c,
    size_t ih,
    size_t iw,
    size_t oh,
    size_t ow
) {
    size_t ni, ci, oy, ox;
    int fy, fx, y0, x0, y1, x1, wy, wx;
    int64_t v00, v01, v10, v11, top, bot, val;

    for (oy = 0; oy < oh; oy++) {
        fy = src_coord_q16((int)oy, (int)oh, (int)ih);
        y0 = fy >> 16;
        wy = fy & 0xFFFF;
        if (y0 < 0) {
            y0 = 0;
            wy = 0;
        }
        if (y0 >= (int)ih) {
            y0 = (int)ih - 1;
            wy = 0;
        }
        y1 = (y0 + 1 < (int)ih) ? y0 + 1 : y0;
        if (y0 == y1) {
            wy = 0;
        }
        for (ox = 0; ox < ow; ox++) {
            fx = src_coord_q16((int)ox, (int)ow, (int)iw);
            x0 = fx >> 16;
            wx = fx & 0xFFFF;
            if (x0 < 0) {
                x0 = 0;
                wx = 0;
            }
            if (x0 >= (int)iw) {
                x0 = (int)iw - 1;
                wx = 0;
            }
            x1 = (x0 + 1 < (int)iw) ? x0 + 1 : x0;
            if (x0 == x1) {
                wx = 0;
            }
            for (ni = 0; ni < n; ni++) {
                for (ci = 0; ci < c; ci++) {
                    v00 = in[((ni * c + ci) * ih + (size_t)y0) * iw + (size_t)x0];
                    v01 = in[((ni * c + ci) * ih + (size_t)y0) * iw + (size_t)x1];
                    v10 = in[((ni * c + ci) * ih + (size_t)y1) * iw + (size_t)x0];
                    v11 = in[((ni * c + ci) * ih + (size_t)y1) * iw + (size_t)x1];
                    top = v00 * (65536 - wx) + v01 * wx;
                    bot = v10 * (65536 - wx) + v11 * wx;
                    val = (top * (65536 - wy) + bot * wy) >> 32;
                    out[((ni * c + ci) * oh + oy) * ow + ox] = (int32_t)val;
                }
            }
        }
    }
}
