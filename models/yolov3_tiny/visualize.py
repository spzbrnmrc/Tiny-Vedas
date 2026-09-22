# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Draw YOLO boxes on images. Host int8 / integer, or the U280 card."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Sequence, Tuple

import torch

from .eval_map import (
    build_model,
    download_coco128,
    iter_dataset,
    load_image,
)
from .card import detect_card
from .int32 import DecodeHeadsInt32, quantize_int32
from .model import YoloV3Tiny
from .post import COCO_NAMES, detections, detections_from_i32, letterbox
from .weights import default_cache_dir, default_weights_path, download_weights, load_darknet_weights

_PALETTE = (
    (255, 56, 56),
    (255, 157, 151),
    (255, 112, 31),
    (255, 178, 29),
    (207, 210, 49),
    (72, 249, 10),
    (146, 204, 23),
    (61, 219, 134),
    (26, 147, 52),
    (0, 212, 187),
    (44, 153, 168),
    (0, 194, 255),
    (52, 69, 147),
    (100, 115, 255),
    (0, 24, 236),
    (132, 56, 255),
    (82, 0, 133),
    (203, 56, 255),
    (255, 149, 200),
    (255, 55, 199),
)


def _require_pil():
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as exc:
        raise SystemExit(
            "visualize needs Pillow. Install with: venv/bin/pip install pillow"
        ) from exc
    return Image, ImageDraw, ImageFont


def draw_detections(
    image_path: Path,
    det: torch.Tensor,
    *,
    title: str,
) -> "Image.Image":
    Image, ImageDraw, ImageFont = _require_pil()
    im = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(im)
    try:
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 14
        )
    except OSError:
        font = ImageFont.load_default()
    rows = det.detach().to(torch.float32)
    for row in rows:
        x1, y1, x2, y2, score, cls_id = (float(v) for v in row.tolist())
        cid = int(cls_id) % len(COCO_NAMES)
        color = _PALETTE[cid % len(_PALETTE)]
        draw.rectangle((x1, y1, x2, y2), outline=color, width=3)
        label = f"{COCO_NAMES[cid]} {score:.2f}"
        bbox = draw.textbbox((x1, y1), label, font=font)
        draw.rectangle(bbox, fill=color)
        draw.text((x1, y1), label, fill=(0, 0, 0), font=font)
    draw.rectangle((0, 0, im.width, 22), fill=(0, 0, 0))
    draw.text((6, 4), title, fill=(255, 255, 255), font=font)
    return im


def _write_gallery(out_dir: Path, items: Sequence[Tuple[str, Path, int]]) -> Path:
    lines = [
        "<!DOCTYPE html><html><head><meta charset='utf-8'>",
        "<title>Tiny-Vedas detections</title>",
        "<style>body{font-family:sans-serif;background:#111;color:#eee;margin:24px}",
        "figure{display:inline-block;margin:8px} img{max-width:420px;height:auto}",
        "figcaption{font-size:13px;margin-top:4px}</style></head><body>",
        "<h1>Tiny-Vedas detections</h1>",
        "<p>Boxes are host NMS on the named backend. Integer / card is not the "
        "float-dequant 0.3469 host eval.</p>",
    ]
    for caption, path, nbox in items:
        lines.append(
            f"<figure><img src='{path.name}' alt='{caption}'>"
            f"<figcaption>{caption} — {nbox} boxes</figcaption></figure>"
        )
    lines.append("</body></html>")
    html = out_dir / "index.html"
    html.write_text("\n".join(lines), encoding="utf-8")
    return html


@torch.no_grad()
def detect_int8(
    model, image: torch.Tensor, size: int, conf: float, iou: float
) -> torch.Tensor:
    _, h, w = image.shape
    canvas, scale, left, top = letterbox(image, size)
    d32, d16 = model(canvas.unsqueeze(0))
    return detections(
        d32,
        d16,
        size,
        conf_thresh=conf,
        iou_thresh=iou,
        orig_hw=(h, w),
        scale=scale,
        left=left,
        top=top,
    )[0]


@torch.no_grad()
def detect_int32(
    backbone,
    decode,
    image: torch.Tensor,
    size: int,
    conf: float,
    iou: float,
) -> torch.Tensor:
    _, h, w = image.shape
    canvas, scale, left, top = letterbox(image, size)
    canvas_i = torch.round(canvas * 255.0).clamp(0, 255).to(torch.int32) - 128
    canvas_i = canvas_i.clamp(-127, 127)
    d32, d16 = backbone(canvas_i.unsqueeze(0))
    boxes, obj, cls = decode(d32, d16)
    return detections_from_i32(
        boxes,
        obj,
        cls,
        conf_thresh=conf,
        iou_thresh=iou,
        orig_hw=(h, w),
        scale=scale,
        left=left,
        top=top,
    )[0]




def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--backend",
        choices=("int8", "int32", "card", "both"),
        default="int8",
        help="int8: host float-dequant. int32: card numerics. both: overlay pair. card: U280",
    )
    parser.add_argument("--weights", type=Path, default=None)
    parser.add_argument("--data", type=Path, default=None)
    parser.add_argument("--size", type=int, default=416, choices=(208, 416))
    parser.add_argument("--conf", type=float, default=None)
    parser.add_argument("--nms-iou", type=float, default=0.45)
    parser.add_argument("--limit", type=int, default=4)
    parser.add_argument(
        "--max-boxes",
        type=int,
        default=12,
        help="Keep the highest-score boxes when drawing (0 = all)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("work/yolo_vis"),
        help="PNG + index.html output directory",
    )
    parser.add_argument("--download", action="store_true")
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="STREAM ELF + dram.hex directory (default work/yolo_card_<size>)",
    )
    parser.add_argument(
        "--eot-timeout",
        type=float,
        default=90.0,
        help="Card EOT timeout in seconds (default 90)",
    )
    parser.add_argument(
        "--cal",
        type=Path,
        default=None,
        help="Requant calibration YAML for int32 / card",
    )
    args = parser.parse_args(argv)

    backends = ("int8", "int32") if args.backend == "both" else (args.backend,)
    conf_int8 = 0.25 if args.conf is None else args.conf
    conf_int32 = 0.05 if args.conf is None else args.conf

    weights = args.weights or default_weights_path()
    if args.download or not weights.is_file():
        weights = download_weights(weights)
    data = args.data or download_coco128(default_cache_dir())
    pairs = iter_dataset(data)[: args.limit]
    if not pairs:
        raise SystemExit("no images in dataset")

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    card_work = (args.work_dir or Path(f"work/yolo_card_{args.size}")).resolve()

    int8_model = None
    int32_backbone = None
    int32_decode = None
    if "int8" in backends:
        int8_model = build_model(int8=True, weights=weights)
    if "int32" in backends:
        float_m = YoloV3Tiny()
        load_darknet_weights(float_m, weights)
        int32_backbone = quantize_int32(float_m, requant=True, cal=args.cal)
        int32_decode = DecodeHeadsInt32(args.size)

    items: List[Tuple[str, Path, int]] = []
    for img_path, _lab in pairs:
        image = load_image(img_path)
        for backend in backends:
            ms = None
            if backend == "int8":
                det = detect_int8(
                    int8_model, image, args.size, conf_int8, args.nms_iou
                )
                conf_used = conf_int8
            elif backend == "card":
                det, elapsed = detect_card(
                    image,
                    args.size,
                    conf_int32,
                    args.nms_iou,
                    card_work,
                    weights=weights,
                    timeout_s=args.eot_timeout,
                    cal=args.cal,
                    decode_on_core=False,
                )
                conf_used = conf_int32
                ms = elapsed * 1e3
            else:
                det = detect_int32(
                    int32_backbone,
                    int32_decode,
                    image,
                    args.size,
                    conf_int32,
                    args.nms_iou,
                )
                conf_used = conf_int32
            n_all = int(det.shape[0])
            if args.max_boxes > 0 and det.shape[0] > args.max_boxes:
                order = det[:, 4].argsort(descending=True)[: args.max_boxes]
                det = det[order]
            title = f"{backend} {args.size}  {img_path.name}  conf={conf_used}"
            if ms is not None:
                title += f"  {ms:.1f}ms"
            im = draw_detections(img_path, det, title=title)
            dest = out_dir / f"{backend}_{img_path.stem}.jpg"
            im.save(dest, quality=90)
            items.append((title, dest, n_all))
            extra = f"  eot={ms:.1f}ms" if ms is not None else ""
            print(f"{dest}  boxes={n_all}  drawn={int(det.shape[0])}{extra}")

    html = _write_gallery(out_dir, items)
    print(f"gallery {html}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
