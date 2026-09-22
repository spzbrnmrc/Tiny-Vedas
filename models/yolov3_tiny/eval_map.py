# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Host mAP@0.5 on the same weights we will ship."""

from __future__ import annotations

import argparse
import sys
import urllib.request
import zipfile
from pathlib import Path
from typing import List, Tuple

import torch
import torch.nn as nn

from .int32 import DecodeHeadsInt32, quantize_int32
from .model import YoloV3Tiny, quantize_int8
from .post import detections, detections_from_i32, letterbox, map50, xywhn_to_xyxy
from .weights import default_cache_dir, default_weights_path, download_weights, load_darknet_weights

COCO128_URL = (
    "https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128.zip"
)


def _require_pil():
    try:
        from PIL import Image
    except ImportError as exc:
        raise SystemExit(
            "eval needs Pillow (and usually numpy). "
            "Install with: venv/bin/pip install pillow numpy"
        ) from exc
    return Image


def load_image(path: Path) -> torch.Tensor:
    Image = _require_pil()
    img = Image.open(path).convert("RGB")
    tensor = torch.tensor(list(img.getdata()), dtype=torch.float32)
    tensor = tensor.view(img.height, img.width, 3).permute(2, 0, 1) / 255.0
    return tensor


def read_yolo_txt(path: Path) -> torch.Tensor:
    if not path.is_file():
        return torch.zeros((0, 5), dtype=torch.float32)
    rows: List[List[float]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) != 5:
            continue
        rows.append([float(p) for p in parts])
    if not rows:
        return torch.zeros((0, 5), dtype=torch.float32)
    return torch.tensor(rows, dtype=torch.float32)


def download_coco128(cache: Path) -> Path:
    root = cache / "coco128"
    img_dir = root / "images" / "train2017"
    if img_dir.is_dir() and any(img_dir.iterdir()):
        return root
    cache.mkdir(parents=True, exist_ok=True)
    zpath = cache / "coco128.zip"
    print(f"Downloading {COCO128_URL}", file=sys.stderr)
    urllib.request.urlretrieve(COCO128_URL, zpath)
    with zipfile.ZipFile(zpath) as zf:
        zf.extractall(cache)
    if not img_dir.is_dir():
        raise RuntimeError(f"coco128 extract missing {img_dir}")
    return root


def iter_dataset(data_root: Path) -> List[Tuple[Path, Path]]:
    """YOLO layout: ``images/<split>/*.jpg`` + ``labels/<split>/*.txt``."""
    pairs: List[Tuple[Path, Path]] = []
    for img_dir in sorted((data_root / "images").glob("*")):
        if not img_dir.is_dir():
            continue
        lab_dir = data_root / "labels" / img_dir.name
        for img in sorted(img_dir.glob("*")):
            if img.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
                continue
            pairs.append((img, lab_dir / f"{img.stem}.txt"))
    if not pairs:
        raise FileNotFoundError(f"no images under {data_root / 'images'}")
    return pairs


@torch.no_grad()
def evaluate(
    model: nn.Module,
    pairs: List[Tuple[Path, Path]],
    size: int,
    *,
    conf_thresh: float,
    iou_thresh: float,
    limit: int | None,
) -> float:
    model.eval()
    preds: List[torch.Tensor] = []
    tgts: List[torch.Tensor] = []
    use = pairs if limit is None else pairs[:limit]
    for img_path, lab_path in use:
        image = load_image(img_path)
        _, h, w = image.shape
        canvas, scale, left, top = letterbox(image, size)
        d32, d16 = model(canvas.unsqueeze(0))
        det = detections(
            d32,
            d16,
            size,
            conf_thresh=conf_thresh,
            iou_thresh=iou_thresh,
            orig_hw=(h, w),
            scale=scale,
            left=left,
            top=top,
        )[0]
        labels = read_yolo_txt(lab_path)
        tgts.append(xywhn_to_xyxy(labels, h, w))
        preds.append(det)
    return map50(preds, tgts)


@torch.no_grad()
def evaluate_int32(
    backbone: nn.Module,
    decode: nn.Module,
    pairs: List[Tuple[Path, Path]],
    size: int,
    *,
    conf_thresh: float,
    iou_thresh: float,
    limit: int | None,
) -> float:
    """Integer backbone+decode, host NMS. Not equated to float-dequant 0.3469."""
    backbone.eval()
    decode.eval()
    preds: List[torch.Tensor] = []
    tgts: List[torch.Tensor] = []
    use = pairs if limit is None else pairs[:limit]
    for img_path, lab_path in use:
        image = load_image(img_path)
        _, h, w = image.shape
        canvas, scale, left, top = letterbox(image, size)
        canvas_i = torch.round(canvas * 255.0).clamp(0, 255).to(torch.int32) - 128
        canvas_i = canvas_i.clamp(-127, 127)
        d32, d16 = backbone(canvas_i.unsqueeze(0))
        boxes, obj, cls = decode(d32, d16)
        det = detections_from_i32(
            boxes,
            obj,
            cls,
            conf_thresh=conf_thresh,
            iou_thresh=iou_thresh,
            orig_hw=(h, w),
            scale=scale,
            left=left,
            top=top,
        )[0]
        labels = read_yolo_txt(lab_path)
        tgts.append(xywhn_to_xyxy(labels, h, w))
        preds.append(det)
    return map50(preds, tgts)


@torch.no_grad()
def evaluate_card(
    pairs: List[Tuple[Path, Path]],
    size: int,
    *,
    weights: Path,
    work_dir: Path,
    conf_thresh: float,
    iou_thresh: float,
    limit: int | None,
    timeout_s: float,
    cal: Path | None,
) -> Tuple[float, float]:
    """STREAM backbone on the U280, host decode+NMS. Returns (mAP@0.5, mean ms)."""
    from .card import detect_card

    preds: List[torch.Tensor] = []
    tgts: List[torch.Tensor] = []
    times_ms: List[float] = []
    use = pairs if limit is None else pairs[:limit]
    n = len(use)
    for i, (img_path, lab_path) in enumerate(use, start=1):
        image = load_image(img_path)
        _, h, w = image.shape
        det, elapsed = detect_card(
            image,
            size,
            conf_thresh,
            iou_thresh,
            work_dir,
            weights=weights,
            timeout_s=timeout_s,
            cal=cal,
            decode_on_core=False,
        )
        ms = elapsed * 1e3
        times_ms.append(ms)
        labels = read_yolo_txt(lab_path)
        tgts.append(xywhn_to_xyxy(labels, h, w))
        preds.append(det)
        print(
            f"[card] {i}/{n} {img_path.name} eot={ms:.1f}ms "
            f"boxes={int(det.shape[0])}",
            flush=True,
        )
    score = map50(preds, tgts)
    mean_ms = (sum(times_ms) / len(times_ms)) if times_ms else 0.0
    return score, mean_ms


def build_model(*, int8: bool, weights: Path) -> nn.Module:
    model = YoloV3Tiny()
    load_darknet_weights(model, weights)
    model.eval()
    if int8:
        return quantize_int8(model)
    return model


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
    parser.add_argument("--conf", type=float, default=0.25)
    parser.add_argument("--nms-iou", type=float, default=0.45)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument(
        "--float",
        action="store_true",
        help="Evaluate fused-off float Darknet weights (default is int8)",
    )
    parser.add_argument(
        "--int32",
        action="store_true",
        help="Integer backbone+decode (requant) and host NMS; not 0.3469",
    )
    parser.add_argument(
        "--card",
        action="store_true",
        help="U280 STREAM backbone, host decode+NMS; prints mAP and ms/frame",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="STREAM ELF directory (default work/yolo_card_<size>)",
    )
    parser.add_argument(
        "--eot-timeout",
        type=float,
        default=400.0,
        help="Card host-EOT timeout in seconds (default 400)",
    )
    parser.add_argument(
        "--cal",
        type=Path,
        default=None,
        help="Requant calibration YAML (off = first-design (1,7)/(1,6))",
    )
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args(argv)

    weights = args.weights or default_weights_path()
    if args.download or not weights.is_file():
        weights = download_weights(weights)

    data = args.data
    if data is None:
        data = download_coco128(default_cache_dir())

    pairs = iter_dataset(data)
    if args.card and args.int32:
        raise SystemExit("use --card or --int32, not both")
    if args.card:
        work_dir = (args.work_dir or Path(f"work/yolo_card_{args.size}")).resolve()
        conf = 0.05 if args.conf == 0.25 else args.conf
        score, mean_ms = evaluate_card(
            pairs,
            args.size,
            weights=weights,
            work_dir=work_dir,
            conf_thresh=conf,
            iou_thresh=args.nms_iou,
            limit=args.limit,
            timeout_s=args.eot_timeout,
            cal=args.cal,
        )
        cal_note = f" cal={args.cal}" if args.cal is not None else ""
        n = args.limit or len(pairs)
        print(
            f"mAP@0.5 card size={args.size} n={n}: {score:.6f} "
            f"(80 MHz; mean {mean_ms:.1f} ms/frame; integer requant; "
            f"not 0.3469){cal_note}"
        )
        return 0 if score > 0 else 1
    if args.int32:
        float_m = YoloV3Tiny()
        load_darknet_weights(float_m, weights)
        backbone = quantize_int32(float_m, requant=True, cal=args.cal)
        decode = DecodeHeadsInt32(args.size)
        score = evaluate_int32(
            backbone,
            decode,
            pairs,
            args.size,
            conf_thresh=0.05,
            iou_thresh=args.nms_iou,
            limit=args.limit,
        )
        cal_note = f" cal={args.cal}" if args.cal is not None else ""
        print(
            f"mAP@0.5 int32 size={args.size} n={args.limit or len(pairs)}: "
            f"{score:.6f} (integer requant; not 0.3469){cal_note}"
        )
        return 0 if score > 0 else 1

    model = build_model(int8=not args.float, weights=weights)
    pairs = iter_dataset(data)
    score = evaluate(
        model,
        pairs,
        args.size,
        conf_thresh=args.conf,
        iou_thresh=args.nms_iou,
        limit=args.limit,
    )
    kind = "float" if args.float else "int8"
    print(f"mAP@0.5 {kind} size={args.size} n={args.limit or len(pairs)}: {score:.4f}")
    if score <= 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
