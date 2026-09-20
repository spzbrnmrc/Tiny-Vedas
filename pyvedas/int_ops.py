# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Integer custom ops for the PyVedas YOLO path (no float in the export)."""

from __future__ import annotations

import torch

# Q8: 256 == 1.0. Used by integer sigmoid / exp.
Q8_ONE = 256
EXP_MIN = -8
EXP_MAX = 8
EXP_LUT = tuple(Q8_ONE * (2 ** e) for e in range(EXP_MIN, EXP_MAX + 1))


@torch.library.custom_op("pyvedas::leaky_relu", mutates_args=())
def leaky_relu(x: torch.Tensor) -> torch.Tensor:
    """int32 leaky: x >= 0 ? x : trunc(x / 10)."""
    x32 = x.to(torch.int32)
    return torch.where(x32 >= 0, x32, torch.div(x32, 10, rounding_mode="trunc"))


@leaky_relu.register_fake
def _(x: torch.Tensor) -> torch.Tensor:
    return torch.empty_like(x, dtype=torch.int32)


@torch.library.custom_op("pyvedas::sigmoid_i32", mutates_args=())
def sigmoid_i32(x: torch.Tensor) -> torch.Tensor:
    """Piecewise linear Q8 logistic: 128 + 16*x, clamped to [0, 256]."""
    y = 128 + x.to(torch.int32) * 16
    return torch.clamp(y, 0, Q8_ONE)


@sigmoid_i32.register_fake
def _(x: torch.Tensor) -> torch.Tensor:
    return torch.empty_like(x, dtype=torch.int32)


@torch.library.custom_op("pyvedas::exp_i32", mutates_args=())
def exp_i32(x: torch.Tensor) -> torch.Tensor:
    """Q8 exp as 256 * 2^clamp(x, -8, 8)."""
    x32 = torch.clamp(x.to(torch.int32), EXP_MIN, EXP_MAX)
    lut = torch.tensor(EXP_LUT, dtype=torch.int32, device=x.device)
    return lut[(x32 - EXP_MIN).to(torch.int64)]


@exp_i32.register_fake
def _(x: torch.Tensor) -> torch.Tensor:
    return torch.empty_like(x, dtype=torch.int32)


def _src_coord_q16(o: int, out_s: int, in_s: int) -> int:
    """align_corners=False source coordinate in Q16."""
    return ((2 * o + 1) * in_s * 65536) // (2 * out_s) - 32768


def upsample_bilinear_int32(
    x: torch.Tensor, out_h: int, out_w: int
) -> torch.Tensor:
    n, c, ih, iw = (int(d) for d in x.shape)
    x32 = x.to(torch.int32)
    out = torch.empty(n, c, out_h, out_w, dtype=torch.int32, device=x.device)
    for oy in range(out_h):
        fy = _src_coord_q16(oy, out_h, ih)
        y0 = fy >> 16
        wy = fy & 0xFFFF
        if y0 < 0:
            y0 = 0
            wy = 0
        if y0 >= ih:
            y0 = ih - 1
            wy = 0
        y1 = y0 + 1 if y0 + 1 < ih else y0
        if y0 == y1:
            wy = 0
        for ox in range(out_w):
            fx = _src_coord_q16(ox, out_w, iw)
            x0 = fx >> 16
            wx = fx & 0xFFFF
            if x0 < 0:
                x0 = 0
                wx = 0
            if x0 >= iw:
                x0 = iw - 1
                wx = 0
            x1 = x0 + 1 if x0 + 1 < iw else x0
            if x0 == x1:
                wx = 0
            v00 = x32[:, :, y0, x0].to(torch.int64)
            v01 = x32[:, :, y0, x1].to(torch.int64)
            v10 = x32[:, :, y1, x0].to(torch.int64)
            v11 = x32[:, :, y1, x1].to(torch.int64)
            top = v00 * (65536 - wx) + v01 * wx
            bot = v10 * (65536 - wx) + v11 * wx
            val = (top * (65536 - wy) + bot * wy) >> 32
            out[:, :, oy, ox] = val.to(torch.int32)
    return out


@torch.library.custom_op("pyvedas::upsample_bilinear", mutates_args=())
def upsample_bilinear(x: torch.Tensor, out_h: int, out_w: int) -> torch.Tensor:
    return upsample_bilinear_int32(x, int(out_h), int(out_w))


@upsample_bilinear.register_fake
def _(x: torch.Tensor, out_h: int, out_w: int) -> torch.Tensor:
    n, c, _, _ = (int(d) for d in x.shape)
    return torch.empty(
        n, c, int(out_h), int(out_w), dtype=torch.int32, device=x.device
    )


def upsample_nearest_int32(
    x: torch.Tensor, out_h: int, out_w: int
) -> torch.Tensor:
    n, c, ih, iw = (int(d) for d in x.shape)
    x32 = x.to(torch.int32)
    out = torch.empty(n, c, out_h, out_w, dtype=torch.int32, device=x.device)
    for oy in range(out_h):
        iy = min((oy * ih) // out_h, ih - 1)
        for ox in range(out_w):
            ix = min((ox * iw) // out_w, iw - 1)
            out[:, :, oy, ox] = x32[:, :, iy, ix]
    return out


@torch.library.custom_op("pyvedas::upsample_nearest", mutates_args=())
def upsample_nearest(x: torch.Tensor, out_h: int, out_w: int) -> torch.Tensor:
    return upsample_nearest_int32(x, int(out_h), int(out_w))


@upsample_nearest.register_fake
def _(x: torch.Tensor, out_h: int, out_w: int) -> torch.Tensor:
    n, c, _, _ = (int(d) for d in x.shape)
    return torch.empty(
        n, c, int(out_h), int(out_w), dtype=torch.int32, device=x.device
    )
