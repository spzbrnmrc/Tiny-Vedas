/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef PYVEDAS_H
#define PYVEDAS_H

#include <stddef.h>
#include <stdint.h>

/* Host and bare-metal callable runtime ("our CUDA").
 *
 * Each function implements one GraphModule op (1:1 with runtime/ops.yaml),
 * except helpers used by the conv2d lowering (im2col / weight pack / bias).
 */

void pyvedas_aten_add_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_aten_mul_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_aten_sub_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_aten_div_Tensor_mode(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_gemm_job(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t m,
    size_t n,
    size_t k,
    size_t m0,
    size_t n0,
    size_t k0,
    size_t m_t,
    size_t n_t,
    size_t k_t,
    uint8_t *scratch
);

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
);

void pyvedas_pack_weight_crs(
    const int32_t *weight,
    int32_t *wt,
    size_t cout,
    size_t cin,
    size_t kh,
    size_t kw
);

void pyvedas_conv_bias_nchw(
    const int32_t *gemm,
    const int32_t *bias,
    int32_t *out,
    size_t n,
    size_t cout,
    size_t oh,
    size_t ow
);

void pyvedas_leaky_relu(const int32_t *x, int32_t *out, size_t n);

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
);

void pyvedas_aten_cat(
    const int32_t **ins,
    const size_t *dim_sizes,
    int32_t *out,
    size_t n,
    size_t outer,
    size_t inner
);

void pyvedas_aten_pad(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    const size_t *out_shape,
    int n_pad,
    const int *pad,
    int32_t value
);

void pyvedas_upsample_nearest(
    const int32_t *in,
    int32_t *out,
    size_t n,
    size_t c,
    size_t ih,
    size_t iw,
    size_t oh,
    size_t ow
);

void pyvedas_upsample_bilinear(
    const int32_t *in,
    int32_t *out,
    size_t n,
    size_t c,
    size_t ih,
    size_t iw,
    size_t oh,
    size_t ow
);

void pyvedas_aten_permute(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    const int *dims
);

void pyvedas_aten_slice(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    size_t dim,
    size_t start,
    size_t end
);

void pyvedas_aten_select(
    const int32_t *in,
    int32_t *out,
    int rank,
    const size_t *in_shape,
    size_t dim,
    size_t index
);

void pyvedas_aten_stack(
    const int32_t **ins,
    int32_t *out,
    size_t n,
    size_t outer,
    size_t inner
);

void pyvedas_aten_arange(int32_t *out, size_t end);

void pyvedas_aten_meshgrid(
    const int32_t *a,
    const int32_t *b,
    int32_t *gy,
    int32_t *gx,
    size_t h,
    size_t w
);

void pyvedas_sigmoid_i32(const int32_t *x, int32_t *out, size_t n);

void pyvedas_exp_i32(const int32_t *x, int32_t *out, size_t n);

#endif
