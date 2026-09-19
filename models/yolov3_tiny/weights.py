# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Official Darknet YOLOv3-Tiny weights: download and load."""

from __future__ import annotations

import struct
import sys
import urllib.request
from pathlib import Path
from typing import Iterable

import torch
import torch.nn as nn

WEIGHT_NAME = "yolov3-tiny.weights"
WEIGHT_URLS = (
    "https://pjreddie.com/media/files/yolov3-tiny.weights",
    "https://data.pjreddie.com/files/yolov3-tiny.weights",
    "https://github.com/ultralytics/yolov3/releases/download/v8/yolov3-tiny.weights",
)
def default_cache_dir() -> Path:
    return Path(__file__).resolve().parents[1] / ".cache"


def default_weights_path() -> Path:
    return default_cache_dir() / WEIGHT_NAME


def download_weights(dest: Path | None = None, *, force: bool = False) -> Path:
    dest = dest or default_weights_path()
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file() and dest.stat().st_size > 0 and not force:
        return dest

    last_err: Exception | None = None
    tmp = dest.with_suffix(dest.suffix + ".part")
    for url in WEIGHT_URLS:
        try:
            print(f"Downloading {url}", file=sys.stderr)
            urllib.request.urlretrieve(url, tmp)
            if tmp.stat().st_size < 1_000_000:
                raise RuntimeError(f"download too small: {tmp.stat().st_size} bytes")
            tmp.replace(dest)
            return dest
        except Exception as exc:  # noqa: BLE001 — try the next mirror
            last_err = exc
            if tmp.exists():
                tmp.unlink()
    raise RuntimeError(f"Failed to download {WEIGHT_NAME}") from last_err


def _payload_floats(path: Path) -> torch.Tensor:
    raw = path.read_bytes()
    if len(raw) < 20:
        raise ValueError(f"weight file too small: {path}")
    major, minor, *_ = struct.unpack_from("<ii", raw, 0)
    # Darknet: 3×int32 version + seen (int32 or int64 when major*10+minor >= 2).
    header = 20 if major * 10 + minor >= 2 else 16
    payload = raw[header:]
    if len(payload) % 4:
        raise ValueError(f"weight payload not float32-aligned: {len(payload)} bytes")
    return torch.frombuffer(bytearray(payload), dtype=torch.float32)


def _copy(dest: torch.Tensor, src: torch.Tensor, offset: int) -> int:
    n = dest.numel()
    dest.copy_(src[offset : offset + n].view_as(dest))
    return offset + n


def load_darknet_weights(module: nn.Module, path: Path | str) -> None:
    """Fill ``module`` conv/BN parameters in Darknet cfg order.

    ``module`` must expose ``darknet_convs()`` — conv layers in file order,
    each either ``ConvBNLeaky`` (BN) or a plain ``nn.Conv2d`` (detect heads).
    """
    floats = _payload_floats(Path(path))
    offset = 0
    convs: Iterable[nn.Module] = module.darknet_convs()
    module.eval()
    with torch.no_grad():
        for layer in convs:
            conv, bn = _split_conv(layer)
            if bn is not None:
                offset = _copy(bn.bias, floats, offset)
                offset = _copy(bn.weight, floats, offset)
                offset = _copy(bn.running_mean, floats, offset)
                offset = _copy(bn.running_var, floats, offset)
                offset = _copy(conv.weight, floats, offset)
            else:
                if conv.bias is None:
                    raise ValueError("detect-head conv must have bias")
                offset = _copy(conv.bias, floats, offset)
                offset = _copy(conv.weight, floats, offset)
    if offset != floats.numel():
        raise ValueError(
            f"weight count mismatch: used {offset}, file has {floats.numel()}"
        )


def _split_conv(layer: nn.Module) -> tuple[nn.Conv2d, nn.BatchNorm2d | None]:
    if isinstance(layer, nn.Conv2d):
        return layer, None
    conv = getattr(layer, "conv", None)
    bn = getattr(layer, "bn", None)
    if not isinstance(conv, nn.Conv2d):
        raise TypeError(f"expected conv layer, got {type(layer)}")
    if bn is not None and not isinstance(bn, nn.BatchNorm2d):
        raise TypeError(f"expected BatchNorm2d, got {type(bn)}")
    return conv, bn


def conv_weight_count(module: nn.Module) -> int:
    total = 0
    for layer in module.darknet_convs():
        conv, _ = _split_conv(layer)
        total += conv.weight.numel()
    return total
