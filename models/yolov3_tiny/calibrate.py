# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Write a requant calibration YAML from a float-dequant Darknet run.

This script knows coco128 and YOLOv3-Tiny. The apply pass only reads the
file.

Eval input is ``round(canvas * 255) - 128``. That is ``x_float = (x_int +
128) / 255``, so ``c0`` uses ``scale_x = 1/255`` and ``zero_point = 128``.
Later layers are zero-point free after requant. Detect heads keep
``scale_y = 1`` so integer decode sees logit-like values. The upsample
skip pair ``(c8, c18)`` shares one ``scale_y`` so concat stays in one
unit.

``(M, S)`` satisfies ``M / 2^S ≈ scale_x * scale_w / scale_y`` using the
integer graph's per-tensor ``scale_w``. A per-channel weight scale cannot
be inverted by scalar ``requant_i32``.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import torch

from .eval_map import download_coco128, iter_dataset, load_image
from .int32 import INT32_CONV_NAMES, quantize_int32
from .model import YoloV3Tiny, quantize_int8
from .post import letterbox
from .weights import default_cache_dir, default_weights_path, download_weights, load_darknet_weights

_PYVEDAS = Path(__file__).resolve().parents[2] / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from requant_cal import (  # noqa: E402
    LayerCal,
    RequantCal,
    choose_mul_shift,
    dump_requant_cal,
)

DETECT_HEADS = frozenset({"c15", "c22"})
CONCAT_PAIR = ("c8", "c18")
PRED_SCALE: Dict[str, str] = {
    "c2": "c0",
    "c4": "c2",
    "c6": "c4",
    "c8": "c6",
    "c10": "c8",
    "c12": "c10",
    "c13": "c12",
    "c14": "c13",
    "c15": "c14",
    "c18": "c13",
    "c21": "concat",
    "c22": "c21",
}
INPUT_SCALE_X = 1.0 / 255.0
INPUT_ZERO_POINT = 128


@torch.no_grad()
def collect_ranges(
    teacher: torch.nn.Module,
    pairs: List[Tuple[Path, Path]],
    size: int,
    limit: int | None,
) -> Dict[str, float]:
    """Per-conv teacher ``out_max`` on letterboxed float images."""
    stats = {name: 0.0 for name in INT32_CONV_NAMES}

    def make_hook(name: str):
        def hook(_mod, _inp, out) -> None:
            stats[name] = max(stats[name], float(out.detach().abs().max()))

        return hook

    handles = [
        getattr(teacher, name).register_forward_hook(make_hook(name))
        for name in INT32_CONV_NAMES
    ]
    teacher.eval()
    use = pairs if limit is None else pairs[:limit]
    try:
        for img_path, _lab in use:
            image = load_image(img_path)
            canvas, _scale, _left, _top = letterbox(image, size)
            teacher(canvas.unsqueeze(0))
    finally:
        for handle in handles:
            handle.remove()
    return stats


def _scale_y(out_max: Dict[str, float]) -> Dict[str, float]:
    shared = max(out_max["c8"], out_max["c18"], 1e-8) / 127.0
    scales: Dict[str, float] = {}
    for name in INT32_CONV_NAMES:
        if name in DETECT_HEADS:
            scales[name] = 1.0
        elif name in CONCAT_PAIR:
            scales[name] = shared
        else:
            scales[name] = max(out_max[name], 1e-8) / 127.0
    return scales


def build_cal(
    float_model: YoloV3Tiny,
    out_max: Dict[str, float],
) -> RequantCal:
    int_model = quantize_int32(float_model, requant=True)
    scale_y = _scale_y(out_max)
    layers: Dict[str, LayerCal] = {}
    for name in INT32_CONV_NAMES:
        layer = getattr(int_model, name)
        scale_w = float(layer.weight_scale.reshape(-1)[0].clamp(min=1e-8))
        if name == "c0":
            scale_x = INPUT_SCALE_X
            zp = INPUT_ZERO_POINT
        elif PRED_SCALE[name] == "concat":
            scale_x = scale_y["c8"]
            zp = 0
        else:
            scale_x = scale_y[PRED_SCALE[name]]
            zp = 0
        real = scale_x * scale_w / scale_y[name]
        mul, shift = choose_mul_shift(real)
        layers[name] = LayerCal(
            scale_x=scale_x,
            requant_mul=mul,
            requant_shift=shift,
            zero_point=zp,
        )
    return RequantCal(version=1, layers=layers)


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, default=None)
    parser.add_argument(
        "--data",
        type=Path,
        default=None,
        help="YOLO dataset root (images/ + labels/). Default: download coco128",
    )
    parser.add_argument("--size", type=int, default=416, choices=(208, 416))
    parser.add_argument("--limit", type=int, default=16)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("work/requant_cal.yaml"),
        help="Calibration YAML path",
    )
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args(argv)

    weights = args.weights or default_weights_path()
    if args.download or not weights.is_file():
        weights = download_weights(weights)
    data = args.data or download_coco128(default_cache_dir())
    pairs = iter_dataset(data)

    float_m = YoloV3Tiny()
    load_darknet_weights(float_m, weights)
    teacher = quantize_int8(float_m).eval()
    out_max = collect_ranges(teacher, pairs, args.size, args.limit)
    cal = build_cal(float_m, out_max)
    dump_requant_cal(cal, args.out)
    print(f"wrote {args.out} layers={len(cal.layers)} size={args.size} n={args.limit}")
    for name, ent in cal.layers.items():
        zp = f" zp={ent.zero_point}" if ent.zero_point else ""
        print(
            f"  {name}: scale_x={ent.scale_x:.6g} "
            f"(M,S)=({ent.requant_mul},{ent.requant_shift}){zp}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
