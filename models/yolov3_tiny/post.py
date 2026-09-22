# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Letterbox, box decode, and NMS. Host-side; also exportable as tensor ops."""

from __future__ import annotations

from typing import List, Sequence, Tuple

import torch
import torch.nn.functional as F

from .model import NUM_CLASSES, decode_pair

# COCO 2017 names, Darknet / YOLO order.
COCO_NAMES: Tuple[str, ...] = (
    "person",
    "bicycle",
    "car",
    "motorcycle",
    "airplane",
    "bus",
    "train",
    "truck",
    "boat",
    "traffic light",
    "fire hydrant",
    "stop sign",
    "parking meter",
    "bench",
    "bird",
    "cat",
    "dog",
    "horse",
    "sheep",
    "cow",
    "elephant",
    "bear",
    "zebra",
    "giraffe",
    "backpack",
    "umbrella",
    "handbag",
    "tie",
    "suitcase",
    "frisbee",
    "skis",
    "snowboard",
    "sports ball",
    "kite",
    "baseball bat",
    "baseball glove",
    "skateboard",
    "surfboard",
    "tennis racket",
    "bottle",
    "wine glass",
    "cup",
    "fork",
    "knife",
    "spoon",
    "bowl",
    "banana",
    "apple",
    "sandwich",
    "orange",
    "broccoli",
    "carrot",
    "hot dog",
    "pizza",
    "donut",
    "cake",
    "chair",
    "couch",
    "potted plant",
    "bed",
    "dining table",
    "toilet",
    "tv",
    "laptop",
    "mouse",
    "remote",
    "keyboard",
    "cell phone",
    "microwave",
    "oven",
    "toaster",
    "sink",
    "refrigerator",
    "book",
    "clock",
    "vase",
    "scissors",
    "teddy bear",
    "hair drier",
    "toothbrush",
)

PAD_VALUE = 114.0 / 255.0


def letterbox(
    image: torch.Tensor, dst: int, pad_value: float = PAD_VALUE
) -> Tuple[torch.Tensor, float, int, int]:
    """Letterbox ``(3,H,W)`` or ``(B,3,H,W)`` in 0–1 RGB to a ``dst`` square.

    Returns ``(canvas, scale, left, top)``.
    """
    squeezed = image.ndim == 3
    if squeezed:
        image = image.unsqueeze(0)
    if image.ndim != 4 or image.shape[1] != 3:
        raise ValueError(f"expected (B,3,H,W), got {tuple(image.shape)}")
    _, _, height, width = image.shape
    scale = min(dst / height, dst / width)
    nh = int(round(height * scale))
    nw = int(round(width * scale))
    resized = F.interpolate(image, size=(nh, nw), mode="bilinear", align_corners=False)
    top = (dst - nh) // 2
    left = (dst - nw) // 2
    canvas = F.pad(
        resized,
        (left, dst - nw - left, top, dst - nh - top),
        value=pad_value,
    )
    if squeezed:
        canvas = canvas.squeeze(0)
    return canvas, scale, left, top


def decode_heads(
    det32: torch.Tensor, det16: torch.Tensor, img_size: int
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    return decode_pair(det32, det16, img_size)


def box_iou(box: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
    """IoU of ``box`` ``(4,)`` xyxy against ``boxes`` ``(N,4)``."""
    tl = torch.maximum(box[:2], boxes[:, :2])
    br = torch.minimum(box[2:], boxes[:, 2:])
    wh = (br - tl).clamp(min=0)
    inter = wh[:, 0] * wh[:, 1]
    area_a = (box[2] - box[0]).clamp(min=0) * (box[3] - box[1]).clamp(min=0)
    area_b = (boxes[:, 2] - boxes[:, 0]).clamp(min=0) * (
        boxes[:, 3] - boxes[:, 1]
    ).clamp(min=0)
    return inter / (area_a + area_b - inter + 1e-9)


def nms(
    boxes: torch.Tensor,
    scores: torch.Tensor,
    iou_thresh: float = 0.45,
) -> torch.Tensor:
    """Greedy NMS. Returns keep indices. Prefer torchvision if present."""
    try:
        from torchvision.ops import nms as tv_nms  # type: ignore

        return tv_nms(boxes, scores, iou_thresh)
    except Exception:
        pass
    if boxes.numel() == 0:
        return torch.zeros(0, dtype=torch.long, device=boxes.device)
    order = scores.argsort(descending=True)
    keep: List[torch.Tensor] = []
    while order.numel() > 0:
        i = order[0]
        keep.append(i)
        if order.numel() == 1:
            break
        rest = order[1:]
        iou = box_iou(boxes[i], boxes[rest])
        order = rest[iou <= iou_thresh]
    return torch.stack(keep)


def detections(
    det32: torch.Tensor,
    det16: torch.Tensor,
    img_size: int,
    *,
    conf_thresh: float = 0.25,
    iou_thresh: float = 0.45,
    orig_hw: Tuple[int, int] | None = None,
    scale: float = 1.0,
    left: int = 0,
    top: int = 0,
) -> List[torch.Tensor]:
    """Per-batch ``(N, 6)`` rows: ``x1,y1,x2,y2,score,class`` in original pixels."""
    boxes, obj, cls = decode_heads(det32, det16, img_size)
    cls_score, cls_id = cls.max(dim=-1)
    score = obj * cls_score
    out: List[torch.Tensor] = []
    for b in range(boxes.shape[0]):
        mask = score[b] > conf_thresh
        bb = boxes[b][mask]
        ss = score[b][mask]
        cc = cls_id[b][mask]
        if bb.numel() == 0:
            out.append(bb.new_zeros((0, 6)))
            continue
        keep_parts: List[torch.Tensor] = []
        for c in cc.unique():
            sel = cc == c
            idx = nms(bb[sel], ss[sel], iou_thresh)
            picked = torch.cat(
                (
                    bb[sel][idx],
                    ss[sel][idx, None],
                    cc[sel][idx, None].to(bb.dtype),
                ),
                dim=1,
            )
            keep_parts.append(picked)
        det = torch.cat(keep_parts, dim=0) if keep_parts else bb.new_zeros((0, 6))
        det[:, [0, 2]] = (det[:, [0, 2]] - left) / scale
        det[:, [1, 3]] = (det[:, [1, 3]] - top) / scale
        if orig_hw is not None:
            h, w = orig_hw
            det[:, [0, 2]] = det[:, [0, 2]].clamp(0, w)
            det[:, [1, 3]] = det[:, [1, 3]].clamp(0, h)
        out.append(det)
    return out


def detections_from_i32(
    boxes: torch.Tensor,
    obj: torch.Tensor,
    cls: torch.Tensor,
    *,
    conf_thresh: float = 0.25,
    iou_thresh: float = 0.45,
    orig_hw: Tuple[int, int] | None = None,
    scale: float = 1.0,
    left: int = 0,
    top: int = 0,
    q8: float = 256.0,
) -> List[torch.Tensor]:
    """Host NMS on integer decode heads. Scores are Q8 (``q8`` == 1.0)."""
    obj_f = obj.to(torch.float32) / q8
    cls_f = cls.to(torch.float32) / q8
    boxes_f = boxes.to(torch.float32)
    cls_score, cls_id = cls_f.max(dim=-1)
    score = obj_f * cls_score
    out: List[torch.Tensor] = []
    for b in range(boxes_f.shape[0]):
        mask = score[b] > conf_thresh
        bb = boxes_f[b][mask]
        ss = score[b][mask]
        cc = cls_id[b][mask]
        if bb.numel() == 0:
            out.append(bb.new_zeros((0, 6)))
            continue
        keep_parts: List[torch.Tensor] = []
        for c in cc.unique():
            sel = cc == c
            idx = nms(bb[sel], ss[sel], iou_thresh)
            picked = torch.cat(
                (
                    bb[sel][idx],
                    ss[sel][idx, None],
                    cc[sel][idx, None].to(bb.dtype),
                ),
                dim=1,
            )
            keep_parts.append(picked)
        det = torch.cat(keep_parts, dim=0) if keep_parts else bb.new_zeros((0, 6))
        det[:, [0, 2]] = (det[:, [0, 2]] - left) / scale
        det[:, [1, 3]] = (det[:, [1, 3]] - top) / scale
        if orig_hw is not None:
            h, w = orig_hw
            det[:, [0, 2]] = det[:, [0, 2]].clamp(0, w)
            det[:, [1, 3]] = det[:, [1, 3]].clamp(0, h)
        out.append(det)
    return out


def xywhn_to_xyxy(labels: torch.Tensor, height: int, width: int) -> torch.Tensor:
    """YOLO-txt ``(cls, cx, cy, w, h)`` normalized → ``(cls, x1, y1, x2, y2)``."""
    if labels.numel() == 0:
        return labels.new_zeros((0, 5))
    cls = labels[:, 0]
    cx, cy, bw, bh = labels[:, 1], labels[:, 2], labels[:, 3], labels[:, 4]
    x1 = (cx - bw * 0.5) * width
    y1 = (cy - bh * 0.5) * height
    x2 = (cx + bw * 0.5) * width
    y2 = (cy + bh * 0.5) * height
    return torch.stack((cls, x1, y1, x2, y2), dim=1)


def map50(
    predictions: Sequence[torch.Tensor],
    targets: Sequence[torch.Tensor],
    num_classes: int = NUM_CLASSES,
    iou_thresh: float = 0.5,
) -> float:
    """Mean AP at one IoU threshold (VOC-style, all-point)."""
    aps: List[float] = []
    for c in range(num_classes):
        scored: List[Tuple[float, int]] = []
        npos = 0
        for pred, tgt in zip(predictions, targets):
            gt = tgt[tgt[:, 0] == c][:, 1:5] if tgt.numel() else tgt.new_zeros((0, 4))
            npos += int(gt.shape[0])
            if pred.numel() == 0:
                continue
            pc = pred[pred[:, 5] == c]
            order = pc[:, 4].argsort(descending=True)
            pc = pc[order]
            matched = torch.zeros(gt.shape[0], dtype=torch.bool)
            for row in pc:
                if gt.shape[0] == 0:
                    scored.append((float(row[4]), 0))
                    continue
                iou = box_iou(row[:4], gt)
                j = int(iou.argmax().item())
                if float(iou[j]) >= iou_thresh and not bool(matched[j]):
                    matched[j] = True
                    scored.append((float(row[4]), 1))
                else:
                    scored.append((float(row[4]), 0))
        if npos == 0:
            continue
        if not scored:
            aps.append(0.0)
            continue
        scored.sort(key=lambda t: t[0], reverse=True)
        tp = 0
        prec: List[float] = []
        rec: List[float] = []
        for i, (_s, hit) in enumerate(scored, start=1):
            tp += hit
            prec.append(tp / i)
            rec.append(tp / npos)
        aps.append(_voc_ap(rec, prec))
    if not aps:
        return 0.0
    return float(sum(aps) / len(aps))


def _voc_ap(rec: Sequence[float], prec: Sequence[float]) -> float:
    mrec = [0.0, *rec, 1.0]
    mpre = [0.0, *prec, 0.0]
    for i in range(len(mpre) - 1, 0, -1):
        mpre[i - 1] = max(mpre[i - 1], mpre[i])
    ap = 0.0
    for i in range(1, len(mrec)):
        if mrec[i] != mrec[i - 1]:
            ap += (mrec[i] - mrec[i - 1]) * mpre[i]
    return ap
