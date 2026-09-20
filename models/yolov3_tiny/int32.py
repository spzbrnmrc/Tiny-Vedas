# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Integer (int32 activations, int8 weights) YOLOv3-Tiny for the PyVedas JIT.

Host mAP stays on ``quantize_int8`` (float dequant). This module is the
export the JIT lowers: no float, no ``to.dtype`` dequant.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterable, List, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

from .model import (
    ANCHOR_MASK_16,
    ANCHOR_MASK_32,
    ANCHORS,
    NUM_ANCHORS,
    NUM_CLASSES,
    ConvBNLeaky,
    Int8Conv,
    MaxPoolSame,
    YoloV3Tiny,
    YoloV3TinyInt8,
    fuse_conv_bn,
    quantize_int8,
)

_PYVEDAS = Path(__file__).resolve().parents[2] / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from conv_op import conv2d  # noqa: E402
from int_ops import (  # noqa: E402
    exp_i32,
    leaky_relu,
    sigmoid_i32,
    upsample_bilinear,
    upsample_nearest,
)

Q8_ONE = 256


class Int32Conv(nn.Module):
    """int8 weights in int32 containers; im2col+GEMM custom op; integer leaky."""

    def __init__(
        self,
        weight_i8: torch.Tensor,
        bias: torch.Tensor,
        stride: int,
        padding: int,
        leaky: bool,
    ) -> None:
        super().__init__()
        self.register_buffer("weight", weight_i8.to(torch.int32))
        self.register_buffer("bias", bias.to(torch.int32))
        self.stride = int(stride)
        self.padding = int(padding)
        self.leaky = bool(leaky)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = conv2d(x, self.weight, self.bias, self.stride, self.padding)
        if self.leaky:
            y = leaky_relu(y)
        return y


class YoloV3TinyInt32(nn.Module):
    """Same topology as ``YoloV3TinyInt8``, integer custom conv / leaky."""

    def __init__(self, convs: List[Int32Conv]) -> None:
        super().__init__()
        if len(convs) != 13:
            raise ValueError(f"expected 13 fused convs, got {len(convs)}")
        (
            self.c0,
            self.c2,
            self.c4,
            self.c6,
            self.c8,
            self.c10,
            self.c12,
            self.c13,
            self.c14,
            self.c15,
            self.c18,
            self.c21,
            self.c22,
        ) = convs
        self.p1 = nn.MaxPool2d(2, 2)
        self.p3 = nn.MaxPool2d(2, 2)
        self.p5 = nn.MaxPool2d(2, 2)
        self.p7 = nn.MaxPool2d(2, 2)
        self.p9 = nn.MaxPool2d(2, 2)
        self.p11 = MaxPoolSame()

    def forward(self, x: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        x = self.c0(x)
        x = self.p1(x)
        x = self.c2(x)
        x = self.p3(x)
        x = self.c4(x)
        x = self.p5(x)
        x = self.c6(x)
        x = self.p7(x)
        skip = self.c8(x)
        x = self.p9(skip)
        x = self.c10(x)
        x = self.p11(x)
        x = self.c12(x)
        feat13 = self.c13(x)
        det32 = self.c15(self.c14(feat13))

        feat_up = self.c18(feat13)
        oh, ow = feat_up.shape[-2] * 2, feat_up.shape[-1] * 2
        if (oh, ow) != tuple(skip.shape[-2:]):
            oh, ow = int(skip.shape[-2]), int(skip.shape[-1])
        up = upsample_nearest(feat_up, oh, ow)
        det16 = self.c22(self.c21(torch.cat((up, skip), dim=1)))
        return det32, det16


def _int32_from_int8_conv(layer: Int8Conv) -> Int32Conv:
    return Int32Conv(
        layer.weight_i8,
        torch.round(layer.bias).to(torch.int32),
        layer.stride,
        layer.padding,
        layer.leaky,
    )


def _fused_int32_conv(layer: nn.Module, leaky: bool) -> Int32Conv:
    if isinstance(layer, nn.Conv2d):
        w = layer.weight.detach()
        b = (
            layer.bias.detach()
            if layer.bias is not None
            else torch.zeros(w.shape[0], dtype=w.dtype)
        )
        stride, padding = layer.stride, layer.padding
    elif isinstance(layer, ConvBNLeaky):
        w, b = fuse_conv_bn(layer.conv, layer.bn)
        stride, padding = layer.conv.stride, layer.conv.padding
        leaky = True
    else:
        raise TypeError(f"cannot fuse {type(layer)}")
    from .model import _quantize_per_out

    w_i8, _scale = _quantize_per_out(w)
    stride_i = stride if isinstance(stride, int) else int(stride[0])
    padding_i = padding if isinstance(padding, int) else int(padding[0])
    return Int32Conv(
        w_i8,
        torch.round(b).to(torch.int32),
        stride_i,
        padding_i,
        leaky=leaky,
    )


def quantize_int32(model: YoloV3Tiny) -> YoloV3TinyInt32:
    """BN-fuse + per-channel weight int8, integer conv/leaky (JIT export)."""
    model.eval()
    leaky_tail = {9: False, 12: False}
    convs: List[Int32Conv] = []
    for i, layer in enumerate(model.darknet_convs()):
        convs.append(_fused_int32_conv(layer, leaky=i not in leaky_tail))
    return YoloV3TinyInt32(convs)


def int32_from_int8(model: YoloV3TinyInt8) -> YoloV3TinyInt32:
    """Drop float scales; reuse int8 kernels and rounded bias."""
    convs = [
        _int32_from_int8_conv(getattr(model, name))
        for name in (
            "c0",
            "c2",
            "c4",
            "c6",
            "c8",
            "c10",
            "c12",
            "c13",
            "c14",
            "c15",
            "c18",
            "c21",
            "c22",
        )
    ]
    return YoloV3TinyInt32(convs)


class LetterboxInt32(nn.Module):
    """Integer letterbox: bilinear upsample + pad. ``H,W`` static at export."""

    def __init__(self, dst: int, pad_value: int = 114) -> None:
        super().__init__()
        self.dst = int(dst)
        self.pad_value = int(pad_value)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        _, _, h, w = x.shape
        dst = self.dst
        scale = min(dst / h, dst / w)
        nh = int(round(int(h) * scale))
        nw = int(round(int(w) * scale))
        y = upsample_bilinear(x, nh, nw)
        top = (dst - nh) // 2
        left = (dst - nw) // 2
        return F.pad(
            y,
            (left, dst - nw - left, top, dst - nh - top),
            value=self.pad_value,
        )


class DecodeHeadsInt32(nn.Module):
    """Integer box decode. Returns ``(xyxy, obj, cls)`` with Q8 sigmoid/exp."""

    def __init__(self, img_size: int) -> None:
        super().__init__()
        self.img_size = int(img_size)

    def forward(
        self, det32: torch.Tensor, det16: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        return decode_pair_i32(det32, det16, self.img_size)


def _mesh_xy_i32(
    h: int, w: int, device: torch.device
) -> torch.Tensor:
    gy, gx = torch.meshgrid(
        torch.arange(h, device=device, dtype=torch.int32),
        torch.arange(w, device=device, dtype=torch.int32),
        indexing="ij",
    )
    return torch.stack((gx, gy), dim=-1)


def decode_one_i32(
    pred: torch.Tensor,
    stride: int,
    anchors: Iterable[Tuple[float, float]],
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    bsz, _, height, width = pred.shape
    pred = pred.view(bsz, NUM_ANCHORS, NUM_CLASSES + 5, height, width)
    pred = pred.permute(0, 1, 3, 4, 2).contiguous()
    q8 = torch.tensor(Q8_ONE, dtype=torch.int32, device=pred.device)
    xy = sigmoid_i32(pred[..., 0:2])
    wh = exp_i32(pred[..., 2:4])
    obj = sigmoid_i32(pred[..., 4])
    cls = sigmoid_i32(pred[..., 5:])
    grid = _mesh_xy_i32(height, width, pred.device)
    anc = torch.tensor(
        [(int(round(a)), int(round(b))) for a, b in anchors],
        device=pred.device,
        dtype=torch.int32,
    ).view(1, NUM_ANCHORS, 1, 1, 2)
    xy_px = (xy + grid * q8) * stride
    xy_px = torch.div(xy_px, q8, rounding_mode="trunc")
    wh_px = torch.div(wh * anc, q8, rounding_mode="trunc")
    half = torch.div(wh_px, 2, rounding_mode="trunc")
    boxes = torch.cat((xy_px - half, xy_px + half), dim=-1)
    boxes = boxes.view(bsz, -1, 4)
    obj = obj.reshape(bsz, -1)
    cls = cls.reshape(bsz, -1, NUM_CLASSES)
    return boxes, obj, cls


def decode_pair_i32(
    det32: torch.Tensor, det16: torch.Tensor, img_size: int
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    a32 = tuple(ANCHORS[i] for i in ANCHOR_MASK_32)
    a16 = tuple(ANCHORS[i] for i in ANCHOR_MASK_16)
    del img_size
    b32, o32, c32 = decode_one_i32(det32, 32, a32)
    b16, o16, c16 = decode_one_i32(det16, 16, a16)
    return (
        torch.cat((b32, b16), dim=1),
        torch.cat((o32, o16), dim=1),
        torch.cat((c32, c16), dim=1),
    )
