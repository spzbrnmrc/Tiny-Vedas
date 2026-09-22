# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Versioned requant calibration file: load, dump, apply.

Any module that owns a scalar ``requant_i32`` (``requant_mul``,
``requant_shift``) and optional ``weight_scale`` / ``bias_f`` can take a
layer entry. The file does not name a net or a dataset.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Mapping

import torch
import torch.nn as nn
import yaml

CAL_VERSION = 1


@dataclass(frozen=True)
class LayerCal:
    scale_x: float
    requant_mul: int
    requant_shift: int
    zero_point: int = 0


@dataclass(frozen=True)
class RequantCal:
    version: int
    layers: Dict[str, LayerCal]


def choose_mul_shift(
    real: float,
    *,
    max_shift: int = 31,
    max_mul: int = 1 << 30,
) -> tuple[int, int]:
    """Integers ``(M, S)`` with ``M / 2^S ≈ real``, ``M >= 1``."""
    target = float(real)
    if not (target > 0.0) or target != target:
        return 1, 0
    best_m, best_s = 1, 0
    best_err = abs(1.0 - target)
    for shift in range(0, int(max_shift) + 1):
        mul = int(round(target * (1 << shift)))
        if mul < 1:
            mul = 1
        if mul > int(max_mul):
            continue
        err = abs(mul / float(1 << shift) - target)
        if err < best_err or (err == best_err and shift < best_s):
            best_m, best_s, best_err = mul, shift, err
    return best_m, best_s


def _as_layer(name: str, raw: Any) -> LayerCal:
    if not isinstance(raw, Mapping):
        raise ValueError(f"layers.{name} must be a mapping")
    try:
        scale_x = float(raw["scale_x"])
        mul = int(raw["requant_mul"])
        shift = int(raw["requant_shift"])
    except KeyError as exc:
        raise ValueError(f"layers.{name} missing {exc}") from exc
    zp = int(raw.get("zero_point", 0))
    if scale_x <= 0.0 or scale_x != scale_x:
        raise ValueError(f"layers.{name} scale_x must be finite and > 0")
    if mul < 1:
        raise ValueError(f"layers.{name} requant_mul must be >= 1")
    if shift < 0:
        raise ValueError(f"layers.{name} requant_shift must be >= 0")
    return LayerCal(
        scale_x=scale_x, requant_mul=mul, requant_shift=shift, zero_point=zp
    )


def load_requant_cal(path: Path | str) -> RequantCal:
    path = Path(path)
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, Mapping):
        raise ValueError(f"{path}: expected a mapping")
    version = int(data.get("version", -1))
    if version != CAL_VERSION:
        raise ValueError(f"{path}: unsupported version {version} (want {CAL_VERSION})")
    raw_layers = data.get("layers", {})
    if not isinstance(raw_layers, Mapping):
        raise ValueError(f"{path}: layers must be a mapping")
    layers = {str(name): _as_layer(str(name), ent) for name, ent in raw_layers.items()}
    return RequantCal(version=version, layers=layers)


def dump_requant_cal(cal: RequantCal, path: Path | str) -> None:
    path = Path(path)
    payload = {
        "version": int(cal.version),
        "layers": {
            name: {
                "scale_x": float(ent.scale_x),
                "requant_mul": int(ent.requant_mul),
                "requant_shift": int(ent.requant_shift),
                **(
                    {"zero_point": int(ent.zero_point)}
                    if int(ent.zero_point) != 0
                    else {}
                ),
            }
            for name, ent in cal.layers.items()
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(payload, sort_keys=False), encoding="utf-8")


def is_requant_conv(mod: nn.Module) -> bool:
    return hasattr(mod, "requant_mul") and hasattr(mod, "requant_shift")


def apply_requant_calibration(model: nn.Module, cal: RequantCal) -> None:
    """Write ``(M, S)`` and scaled bias onto matching named modules.

    Missing layer keys are left unchanged. Bias rewrite needs ``weight_scale``
    (per-out) and fused float ``bias_f`` on the module; otherwise only
    ``requant_mul`` / ``requant_shift`` are set.
    """
    for name, mod in model.named_modules():
        if name not in cal.layers or not is_requant_conv(mod):
            continue
        entry = cal.layers[name]
        mod.requant_mul = int(entry.requant_mul)
        mod.requant_shift = int(entry.requant_shift)
        scale_w = getattr(mod, "weight_scale", None)
        bias_f = getattr(mod, "bias_f", None)
        if scale_w is None or bias_f is None or not hasattr(mod, "bias"):
            continue
        scale_w = torch.as_tensor(scale_w, dtype=torch.float32)
        bias_f = torch.as_tensor(bias_f, dtype=torch.float32)
        denom = (scale_w * float(entry.scale_x)).clamp(min=1e-12)
        bias_i = bias_f / denom
        zp = int(entry.zero_point)
        if zp != 0 and hasattr(mod, "weight"):
            wsum = torch.as_tensor(mod.weight, dtype=torch.float32).sum(dim=(1, 2, 3))
            if wsum.numel() != bias_i.numel():
                raise ValueError(f"{name}: weight sum {tuple(wsum.shape)} != bias")
            bias_i = bias_i + float(zp) * wsum
        bias_i = torch.round(bias_i).to(torch.int32)
        if tuple(mod.bias.shape) != tuple(bias_i.shape):
            raise ValueError(
                f"{name}: bias shape {tuple(mod.bias.shape)} != {tuple(bias_i.shape)}"
            )
        mod.bias.copy_(bias_i)
