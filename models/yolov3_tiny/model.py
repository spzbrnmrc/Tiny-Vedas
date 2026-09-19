# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Darknet YOLOv3-Tiny: conv / leaky ReLU / max-pool / upsample / concat.

The architecture matches ``yolov3-tiny.cfg``. Detect heads stay linear.
Input spatial size should be a multiple of 32 for a clean skip (416).
208 is supported: the upsample/skip concat is aligned with nearest
interpolate when the floored /32 grid does not match /16.
"""

from __future__ import annotations

from typing import Iterable, List, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

# Sum of convolutional kernels (no BN). Paper: ~8.7 M weights.
NUM_CONV_WEIGHTS = 8_845_488
LEAKY_SLOPE = 0.1
# Darknet ``.000001f``.
BN_EPS = 1e-6

# Pixel anchors at the network input (cfg). Masks: stride-32 uses 3,4,5;
# stride-16 uses 0,1,2.
ANCHORS: Tuple[Tuple[float, float], ...] = (
    (10.0, 14.0),
    (23.0, 27.0),
    (37.0, 58.0),
    (81.0, 82.0),
    (135.0, 169.0),
    (344.0, 319.0),
)
ANCHOR_MASK_32 = (3, 4, 5)
ANCHOR_MASK_16 = (0, 1, 2)
NUM_CLASSES = 80
NUM_ANCHORS = 3
PRED_CH = NUM_ANCHORS * (NUM_CLASSES + 5)  # 255


class ConvBNLeaky(nn.Module):
    def __init__(self, c_in: int, c_out: int, k: int, stride: int = 1) -> None:
        super().__init__()
        pad = (k - 1) // 2
        self.conv = nn.Conv2d(c_in, c_out, k, stride=stride, padding=pad, bias=False)
        self.bn = nn.BatchNorm2d(c_out, eps=BN_EPS, momentum=0.1)
        self.act = nn.LeakyReLU(LEAKY_SLOPE, inplace=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.act(self.bn(self.conv(x)))


class MaxPoolSame(nn.Module):
    """Darknet ``[maxpool] size=2 stride=1``: pad right/bottom, keep spatial."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.pad(x, (0, 1, 0, 1))
        return F.max_pool2d(x, kernel_size=2, stride=1)


class YoloV3Tiny(nn.Module):
    """Backbone + two detect heads. Returns ``(det_stride32, det_stride16)``."""

    def __init__(self, num_classes: int = NUM_CLASSES) -> None:
        super().__init__()
        if num_classes != NUM_CLASSES:
            raise ValueError("official weights are 80-class COCO")
        pred = NUM_ANCHORS * (num_classes + 5)

        self.c0 = ConvBNLeaky(3, 16, 3)
        self.p1 = nn.MaxPool2d(2, 2)
        self.c2 = ConvBNLeaky(16, 32, 3)
        self.p3 = nn.MaxPool2d(2, 2)
        self.c4 = ConvBNLeaky(32, 64, 3)
        self.p5 = nn.MaxPool2d(2, 2)
        self.c6 = ConvBNLeaky(64, 128, 3)
        self.p7 = nn.MaxPool2d(2, 2)
        self.c8 = ConvBNLeaky(128, 256, 3)
        self.p9 = nn.MaxPool2d(2, 2)
        self.c10 = ConvBNLeaky(256, 512, 3)
        self.p11 = MaxPoolSame()
        self.c12 = ConvBNLeaky(512, 1024, 3)
        self.c13 = ConvBNLeaky(1024, 256, 1)
        self.c14 = ConvBNLeaky(256, 512, 3)
        self.c15 = nn.Conv2d(512, pred, 1, bias=True)
        self.c18 = ConvBNLeaky(256, 128, 1)
        self.c21 = ConvBNLeaky(256 + 128, 256, 3)
        self.c22 = nn.Conv2d(256, pred, 1, bias=True)

    def darknet_convs(self) -> List[nn.Module]:
        """Conv modules in ``yolov3-tiny.weights`` order."""
        return [
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
        ]

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

        up = F.interpolate(self.c18(feat13), scale_factor=2.0, mode="nearest")
        if up.shape[-2:] != skip.shape[-2:]:
            up = F.interpolate(up, size=skip.shape[-2:], mode="nearest")
        det16 = self.c22(self.c21(torch.cat((up, skip), dim=1)))
        return det32, det16


class Int8Conv(nn.Module):
    """int8 weights, per-out-channel scale, float (or dequant) conv2d."""

    def __init__(
        self,
        weight_i8: torch.Tensor,
        scale: torch.Tensor,
        bias: torch.Tensor,
        stride: int | Tuple[int, int],
        padding: int | Tuple[int, int],
        leaky: bool,
    ) -> None:
        super().__init__()
        self.register_buffer("weight_i8", weight_i8.to(torch.int8))
        self.register_buffer("scale", scale.to(torch.float32))
        self.register_buffer("bias", bias.to(torch.float32))
        self.stride = stride if isinstance(stride, int) else int(stride[0])
        self.padding = padding if isinstance(padding, int) else int(padding[0])
        self.leaky = leaky

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        weight = self.weight_i8.to(dtype=x.dtype) * self.scale.view(-1, 1, 1, 1)
        y = F.conv2d(x, weight, self.bias.to(dtype=x.dtype), self.stride, self.padding)
        if self.leaky:
            y = F.leaky_relu(y, LEAKY_SLOPE)
        return y


class YoloV3TinyInt8(nn.Module):
    """Same topology as ``YoloV3Tiny`` after BN fuse; int8 kernels + scales."""

    def __init__(self, convs: List[Int8Conv]) -> None:
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

        up = F.interpolate(self.c18(feat13), scale_factor=2.0, mode="nearest")
        if up.shape[-2:] != skip.shape[-2:]:
            up = F.interpolate(up, size=skip.shape[-2:], mode="nearest")
        det16 = self.c22(self.c21(torch.cat((up, skip), dim=1)))
        return det32, det16


def fuse_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> Tuple[torch.Tensor, torch.Tensor]:
    w = conv.weight.detach()
    gamma = bn.weight.detach()
    beta = bn.bias.detach()
    mean = bn.running_mean.detach()
    var = bn.running_var.detach()
    std = torch.sqrt(var + bn.eps)
    scale = gamma / std
    w_f = w * scale.view(-1, 1, 1, 1)
    b_in = (
        conv.bias.detach()
        if conv.bias is not None
        else torch.zeros(w.shape[0], dtype=w.dtype, device=w.device)
    )
    b_f = beta + (b_in - mean) * scale
    return w_f, b_f


def _quantize_per_out(weight: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
    max_abs = weight.detach().abs().amax(dim=(1, 2, 3)).clamp(min=1e-8)
    scale = max_abs / 127.0
    q = torch.clamp(torch.round(weight / scale.view(-1, 1, 1, 1)), -128, 127)
    return q.to(torch.int8), scale.to(torch.float32)


def _fused_int8_conv(layer: nn.Module, leaky: bool) -> Int8Conv:
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
    w_i8, scale = _quantize_per_out(w)
    return Int8Conv(w_i8, scale, b, stride, padding, leaky=leaky)


def quantize_int8(model: YoloV3Tiny) -> YoloV3TinyInt8:
    """BN-fuse + per-channel weight int8. Detect heads stay linear (no leaky)."""
    model.eval()
    leaky_tail = {9: False, 12: False}  # c15, c22 in darknet_convs order
    convs: List[Int8Conv] = []
    for i, layer in enumerate(model.darknet_convs()):
        convs.append(_fused_int8_conv(layer, leaky=i not in leaky_tail))
    return YoloV3TinyInt8(convs)


class Letterbox(nn.Module):
    """Resize-with-pad to a square. Static ``H,W`` so ``torch.export`` sees it."""

    def __init__(self, dst: int, pad_value: float = 114.0 / 255.0) -> None:
        super().__init__()
        self.dst = int(dst)
        self.pad_value = float(pad_value)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        _, _, h, w = x.shape
        dst = self.dst
        scale = min(dst / h, dst / w)
        nh = int(round(int(h) * scale))
        nw = int(round(int(w) * scale))
        y = F.interpolate(x, size=(nh, nw), mode="bilinear", align_corners=False)
        top = (dst - nh) // 2
        left = (dst - nw) // 2
        return F.pad(
            y,
            (left, dst - nw - left, top, dst - nh - top),
            value=self.pad_value,
        )


class DecodeHeads(nn.Module):
    """Box decode for both heads. Returns ``(xyxy, obj, cls)`` flat over anchors."""

    def __init__(self, img_size: int) -> None:
        super().__init__()
        self.img_size = int(img_size)

    def forward(
        self, det32: torch.Tensor, det16: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        return decode_pair(det32, det16, self.img_size)


def _mesh_xy(h: int, w: int, device: torch.device, dtype: torch.dtype) -> torch.Tensor:
    gy, gx = torch.meshgrid(
        torch.arange(h, device=device, dtype=dtype),
        torch.arange(w, device=device, dtype=dtype),
        indexing="ij",
    )
    return torch.stack((gx, gy), dim=-1)


def decode_one(
    pred: torch.Tensor,
    stride: int,
    anchors: Iterable[Tuple[float, float]],
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """``pred`` is ``(B, 255, H, W)``. Boxes in input-pixel xyxy."""
    bsz, _, height, width = pred.shape
    pred = pred.view(bsz, NUM_ANCHORS, NUM_CLASSES + 5, height, width)
    pred = pred.permute(0, 1, 3, 4, 2).contiguous()
    xy = torch.sigmoid(pred[..., 0:2])
    wh = torch.exp(pred[..., 2:4])
    obj = torch.sigmoid(pred[..., 4])
    cls = torch.sigmoid(pred[..., 5:])
    grid = _mesh_xy(height, width, pred.device, pred.dtype)
    anc = torch.tensor(list(anchors), device=pred.device, dtype=pred.dtype).view(
        1, NUM_ANCHORS, 1, 1, 2
    )
    xy = (xy + grid) * stride
    wh = wh * anc
    half = wh * 0.5
    boxes = torch.cat((xy - half, xy + half), dim=-1)
    boxes = boxes.view(bsz, -1, 4)
    obj = obj.reshape(bsz, -1)
    cls = cls.reshape(bsz, -1, NUM_CLASSES)
    return boxes, obj, cls


def decode_pair(
    det32: torch.Tensor, det16: torch.Tensor, img_size: int
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    a32 = tuple(ANCHORS[i] for i in ANCHOR_MASK_32)
    a16 = tuple(ANCHORS[i] for i in ANCHOR_MASK_16)
    # img_size is unused for the math (stride is absolute) but kept so the
    # exported module is bound to one input size.
    del img_size
    b32, o32, c32 = decode_one(det32, 32, a32)
    b16, o16, c16 = decode_one(det16, 16, a16)
    return (
        torch.cat((b32, b16), dim=1),
        torch.cat((o32, o16), dim=1),
        torch.cat((c32, c16), dim=1),
    )
