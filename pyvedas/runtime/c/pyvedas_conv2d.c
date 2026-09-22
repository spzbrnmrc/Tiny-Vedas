/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * im2col + weight pack + NCHW bias for pyvedas.conv2d (GEMM is pyvedas_gemm_job).
 */

#include "pyvedas.h"

void pyvedas_im2col(
    const int32_t *x,
    int32_t *col,
    size_t n,
    size_t cin,
    size_t h,
    size_t w,
    size_t kh,
    size_t kw,
    size_t stride,
    size_t pad,
    size_t oh,
    size_t ow
) {
    size_t kdim = cin * kh * kw;
    size_t idx = 0;
    size_t ni, hi, wi, ci, r, s, kd;
    long y, xc;
    size_t yy, xx;

    for (ni = 0; ni < n; ni++) {
        for (hi = 0; hi < oh; hi++) {
            for (wi = 0; wi < ow; wi++) {
                kd = 0;
                for (ci = 0; ci < cin; ci++) {
                    for (r = 0; r < kh; r++) {
                        for (s = 0; s < kw; s++) {
                            y = (long)(hi * stride + r) - (long)pad;
                            xc = (long)(wi * stride + s) - (long)pad;
                            if (y >= 0 && y < (long)h && xc >= 0 && xc < (long)w) {
                                yy = (size_t)y;
                                xx = (size_t)xc;
                                col[idx * kdim + kd] =
                                    x[((ni * cin + ci) * h + yy) * w + xx];
                            } else {
                                col[idx * kdim + kd] = 0;
                            }
                            kd++;
                        }
                    }
                }
                idx++;
            }
        }
    }
}

void pyvedas_pack_weight_crs(
    const int32_t *weight,
    int32_t *wt,
    size_t cout,
    size_t cin,
    size_t kh,
    size_t kw
) {
    size_t oc, c, r, s, crs;
    for (oc = 0; oc < cout; oc++) {
        for (c = 0; c < cin; c++) {
            for (r = 0; r < kh; r++) {
                for (s = 0; s < kw; s++) {
                    crs = c * kh * kw + r * kw + s;
                    wt[crs * cout + oc] =
                        weight[((oc * cin + c) * kh + r) * kw + s];
                }
            }
        }
    }
}

void pyvedas_im2col_tile(
    const int32_t *x,
    int32_t *col,
    size_t n,
    size_t cin,
    size_t h,
    size_t w,
    size_t kh,
    size_t kw,
    size_t stride,
    size_t pad,
    size_t oh,
    size_t ow,
    size_t oh0,
    size_t ow0,
    size_t oh_t,
    size_t ow_t
) {
    size_t kdim = cin * kh * kw;
    size_t idx = 0;
    size_t ni, hi, wi, ci, r, s, kd;
    long y, xc;
    size_t yy, xx;
    size_t hi_end = oh0 + oh_t;
    size_t wi_end = ow0 + ow_t;
    (void)oh;
    (void)ow;
    if (hi_end > oh) {
        hi_end = oh;
    }
    if (wi_end > ow) {
        wi_end = ow;
    }

    for (ni = 0; ni < n; ni++) {
        for (hi = oh0; hi < hi_end; hi++) {
            for (wi = ow0; wi < wi_end; wi++) {
                kd = 0;
                for (ci = 0; ci < cin; ci++) {
                    for (r = 0; r < kh; r++) {
                        for (s = 0; s < kw; s++) {
                            y = (long)(hi * stride + r) - (long)pad;
                            xc = (long)(wi * stride + s) - (long)pad;
                            if (y >= 0 && y < (long)h && xc >= 0 && xc < (long)w) {
                                yy = (size_t)y;
                                xx = (size_t)xc;
                                col[idx * kdim + kd] =
                                    x[((ni * cin + ci) * h + yy) * w + xx];
                            } else {
                                col[idx * kdim + kd] = 0;
                            }
                            kd++;
                        }
                    }
                }
                idx++;
            }
        }
    }
}

void pyvedas_pack_weight_crs_tile(
    const int32_t *weight,
    int32_t *wt,
    size_t cout,
    size_t cin,
    size_t kh,
    size_t kw,
    size_t oc0,
    size_t oc_t
) {
    size_t oc, c, r, s, crs;
    size_t oc_end = oc0 + oc_t;
    if (oc_end > cout) {
        oc_end = cout;
    }
    for (oc = oc0; oc < oc_end; oc++) {
        for (c = 0; c < cin; c++) {
            for (r = 0; r < kh; r++) {
                for (s = 0; s < kw; s++) {
                    crs = c * kh * kw + r * kw + s;
                    wt[crs * oc_t + (oc - oc0)] =
                        weight[((oc * cin + c) * kh + r) * kw + s];
                }
            }
        }
    }
}

void pyvedas_pack_weight_i8_crs_tile(
    const int8_t *weight,
    int32_t *wt,
    size_t cout,
    size_t cin,
    size_t kh,
    size_t kw,
    size_t oc0,
    size_t oc_t
) {
    size_t oc, c, r, s, crs;
    size_t oc_end = oc0 + oc_t;
    if (oc_end > cout) {
        oc_end = cout;
    }
    for (oc = oc0; oc < oc_end; oc++) {
        for (c = 0; c < cin; c++) {
            for (r = 0; r < kh; r++) {
                for (s = 0; s < kw; s++) {
                    crs = c * kh * kw + r * kw + s;
                    wt[crs * oc_t + (oc - oc0)] =
                        (int32_t)weight[((oc * cin + c) * kh + r) * kw + s];
                }
            }
        }
    }
}

void pyvedas_conv_bias_nchw_tile(
    const int32_t *gemm,
    const int32_t *bias,
    int32_t *out,
    size_t n,
    size_t cout,
    size_t oh,
    size_t ow,
    size_t oh0,
    size_t ow0,
    size_t oh_t,
    size_t ow_t,
    size_t oc0,
    size_t oc_t
) {
    size_t ni, oc, y, x, m_t;
    size_t hi_end = oh0 + oh_t;
    size_t wi_end = ow0 + ow_t;
    size_t oc_end = oc0 + oc_t;
    if (hi_end > oh) {
        hi_end = oh;
    }
    if (wi_end > ow) {
        wi_end = ow;
    }
    if (oc_end > cout) {
        oc_end = cout;
    }
    m_t = (hi_end - oh0) * (wi_end - ow0);
    for (ni = 0; ni < n; ni++) {
        for (oc = oc0; oc < oc_end; oc++) {
            for (y = oh0; y < hi_end; y++) {
                for (x = ow0; x < wi_end; x++) {
                    size_t mr = (y - oh0) * (wi_end - ow0) + (x - ow0);
                    out[((ni * cout + oc) * oh + y) * ow + x] =
                        gemm[(ni * m_t + mr) * oc_t + (oc - oc0)] + bias[oc];
                }
            }
        }
    }
}

void pyvedas_conv_bias_nchw(
    const int32_t *gemm,
    const int32_t *bias,
    int32_t *out,
    size_t n,
    size_t cout,
    size_t oh,
    size_t ow
) {
    size_t ni, oc, y, x, m;
    m = oh * ow;
    for (ni = 0; ni < n; ni++) {
        for (oc = 0; oc < cout; oc++) {
            for (y = 0; y < oh; y++) {
                for (x = 0; x < ow; x++) {
                    out[((ni * cout + oc) * oh + y) * ow + x] =
                        gemm[(ni * m + y * ow + x) * cout + oc] + bias[oc];
                }
            }
        }
    }
}
