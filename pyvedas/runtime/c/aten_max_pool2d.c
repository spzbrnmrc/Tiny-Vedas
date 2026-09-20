/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Windowed max-pool. Unmasked vmax folds kernel rows (W unit-stride), then
 * scalar max along kernel width.
 */

#include "pyvedas.h"

#if defined(__riscv_vector)
#include <riscv_vector.h>
#endif

static int32_t pool_at(
    const int32_t *x,
    size_t n_i,
    size_t c_i,
    size_t h,
    size_t w,
    size_t c,
    long y,
    long xc,
    size_t pad_h,
    size_t pad_w
) {
    long yy = y - (long)pad_h;
    long xx = xc - (long)pad_w;
    if (yy < 0 || yy >= (long)h || xx < 0 || xx >= (long)w) {
        return (int32_t)0x80000000;
    }
    return x[((n_i * c + c_i) * h + (size_t)yy) * w + (size_t)xx];
}

void pyvedas_aten_max_pool2d(
    const int32_t *x,
    int32_t *out,
    size_t n,
    size_t c,
    size_t h,
    size_t w,
    size_t oh,
    size_t ow,
    size_t kh,
    size_t kw,
    size_t sh,
    size_t sw,
    size_t pad_h,
    size_t pad_w
) {
    size_t ni, ci, oy, ox, r, s;

#if defined(__riscv_vector)
    if (pad_h == 0 && pad_w == 0 && kh >= 1 && w > 0 && w <= 64) {
        static int32_t rowmax[64];
        for (ni = 0; ni < n; ni++) {
            for (ci = 0; ci < c; ci++) {
                for (oy = 0; oy < oh; oy++) {
                    size_t y0 = oy * sh;
                    const int32_t *row0 =
                        x + ((ni * c + ci) * h + y0) * w;
                    size_t i = 0;
                    while (i < w) {
                        size_t vl = __riscv_vsetvl_e32m1(w - i);
                        vint32m1_t acc = __riscv_vle32_v_i32m1(row0 + i, vl);
                        for (r = 1; r < kh; r++) {
                            size_t yy = y0 + r;
                            if (yy >= h) {
                                break;
                            }
                            const int32_t *row =
                                x + ((ni * c + ci) * h + yy) * w;
                            vint32m1_t vr = __riscv_vle32_v_i32m1(row + i, vl);
                            acc = __riscv_vmax_vv_i32m1(acc, vr, vl);
                        }
                        __riscv_vse32_v_i32m1(rowmax + i, acc, vl);
                        i += vl;
                    }
                    for (ox = 0; ox < ow; ox++) {
                        int32_t m = (int32_t)0x80000000;
                        size_t x0 = ox * sw;
                        for (s = 0; s < kw; s++) {
                            size_t xx = x0 + s;
                            if (xx < w && rowmax[xx] > m) {
                                m = rowmax[xx];
                            }
                        }
                        out[((ni * c + ci) * oh + oy) * ow + ox] = m;
                    }
                }
            }
        }
        return;
    }
#endif
    for (ni = 0; ni < n; ni++) {
        for (ci = 0; ci < c; ci++) {
            for (oy = 0; oy < oh; oy++) {
                for (ox = 0; ox < ow; ox++) {
                    int32_t m = (int32_t)0x80000000;
                    for (r = 0; r < kh; r++) {
                        for (s = 0; s < kw; s++) {
                            long y = (long)(oy * sh + r);
                            long xc = (long)(ox * sw + s);
                            int32_t v = pool_at(
                                x, ni, ci, h, w, c, y, xc, pad_h, pad_w
                            );
                            if (v > m) {
                                m = v;
                            }
                        }
                    }
                    out[((ni * c + ci) * oh + oy) * ow + ox] = m;
                }
            }
        }
    }
}
