# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""GraphModule custom op: int8 conv via im2col + int32 matmul (GEMM contract)."""

from __future__ import annotations

from typing import Tuple

import torch


def conv_out_hw(
    h: int, w: int, kh: int, kw: int, stride: int, padding: int
) -> Tuple[int, int]:
    oh = (h + 2 * padding - kh) // stride + 1
    ow = (w + 2 * padding - kw) // stride + 1
    if oh <= 0 or ow <= 0:
        raise ValueError(f"conv2d output spatial is empty ({oh}x{ow})")
    return oh, ow


def im2col_nchw(
    x: torch.Tensor, kh: int, kw: int, stride: int, padding: int
) -> torch.Tensor:
    """Row-major im2col: (N*OH*OW, Cin*KH*KW), int32."""
    n, cin, h, w = (int(d) for d in x.shape)
    oh, ow = conv_out_hw(h, w, kh, kw, stride, padding)
    x32 = x.to(torch.int32)
    col = torch.nn.functional.unfold(
        x32.to(torch.float32),
        kernel_size=(kh, kw),
        padding=padding,
        stride=stride,
    )
    # unfold is exact for |x| < 2^24 (YOLO int8-range activations).
    return (
        col.to(torch.int32)
        .permute(0, 2, 1)
        .contiguous()
        .reshape(n * oh * ow, cin * kh * kw)
    )


def conv2d_int32(
    x: torch.Tensor,
    weight: torch.Tensor,
    bias: torch.Tensor,
    stride: int,
    padding: int,
) -> torch.Tensor:
    """im2col + int32 matmul + bias. Weight is OIHW; values are int8-in-int32."""
    x = x.to(torch.int32)
    weight = weight.to(torch.int32)
    bias = bias.to(torch.int32)
    n, cin, h, w = (int(d) for d in x.shape)
    cout, cin_w, kh, kw = (int(d) for d in weight.shape)
    if cin != cin_w:
        raise ValueError(f"conv2d Cin mismatch ({cin} vs {cin_w})")
    oh, ow = conv_out_hw(h, w, kh, kw, stride, padding)
    col = im2col_nchw(x, kh, kw, stride, padding)
    kdim = cin * kh * kw
    wt = weight.reshape(cout, kdim).transpose(0, 1).contiguous()
    gemm = torch.matmul(col, wt)
    out = gemm.reshape(n, oh, ow, cout).permute(0, 3, 1, 2).contiguous()
    return out + bias.view(1, -1, 1, 1)


@torch.library.custom_op("pyvedas::conv2d", mutates_args=())
def conv2d(
    x: torch.Tensor,
    weight: torch.Tensor,
    bias: torch.Tensor,
    stride: int,
    padding: int,
) -> torch.Tensor:
    """Eager golden matching the hardware im2col + int8 GEMM contract."""
    return conv2d_int32(x, weight, bias, int(stride), int(padding))


@conv2d.register_fake
def _(
    x: torch.Tensor,
    weight: torch.Tensor,
    bias: torch.Tensor,
    stride: int,
    padding: int,
) -> torch.Tensor:
    n, _, h, w = (int(d) for d in x.shape)
    cout, _, kh, kw = (int(d) for d in weight.shape)
    oh, ow = conv_out_hw(h, w, kh, kw, int(stride), int(padding))
    return torch.empty(n, cout, oh, ow, dtype=torch.int32, device=x.device)
