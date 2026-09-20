# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Walk ``torch.export`` of YOLOv3-Tiny. Name every ``call_function``."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, List, Tuple

import torch
import torch.fx as fx
import torch.nn as nn

from .int32 import (
    DecodeHeadsInt32,
    LetterboxInt32,
    YoloV3TinyInt32,
    quantize_int32,
)
from .model import DecodeHeads, Letterbox, YoloV3Tiny, quantize_int8


def _target_name(target: Any) -> str:
    if isinstance(target, str):
        return target
    as_str = str(target)
    if as_str.startswith(
        ("aten.", "operator.", "torchvision.", "quantized.", "pyvedas.")
    ):
        return as_str
    name = getattr(target, "__name__", None)
    if name:
        return name
    return as_str


def export_module(
    model: nn.Module, example: Tuple[Any, ...]
) -> tuple[fx.GraphModule, str]:
    model.eval()
    try:
        exported = torch.export.export(model, example)
        gm = exported.module()
        return gm, "torch.export"
    except Exception as exc:  # noqa: BLE001
        try:
            gm = fx.symbolic_trace(model)
            return gm, f"symbolic_trace (export failed: {exc})"
        except Exception:
            raise RuntimeError(f"torch.export failed: {exc}") from exc


def call_functions(graph: fx.Graph) -> List[str]:
    names: List[str] = []
    for node in graph.nodes:
        if node.op == "call_function":
            names.append(_target_name(node.target))
    return names


def dump_graph(
    gm: fx.GraphModule,
    backend: str,
    out_txt: Path,
    out_json: Path,
) -> dict[str, Any]:
    names = call_functions(gm.graph)
    counts = Counter(names)
    lines = [
        f"# backend: {backend}",
        f"# call_function count: {len(names)}",
        f"# unique: {len(counts)}",
        "",
        "## unique call_function (name  count)",
        "",
    ]
    for name, n in sorted(counts.items()):
        lines.append(f"{name}  {n}")
    lines.extend(["", "## FX nodes", ""])
    for node in gm.graph.nodes:
        target = _target_name(node.target) if node.op == "call_function" else ""
        lines.append(f"{node.op:16} {node.name:20} {target}")
    out_txt.parent.mkdir(parents=True, exist_ok=True)
    out_txt.write_text("\n".join(lines) + "\n", encoding="utf-8")
    payload = {
        "backend": backend,
        "call_function": names,
        "unique": sorted(counts.keys()),
        "counts": dict(sorted(counts.items())),
    }
    out_json.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def required_ops_present(unique: Iterable[str]) -> dict[str, bool]:
    blob = " ".join(unique)
    return {
        "conv2d": "conv2d" in blob,
        "leaky_relu": "leaky_relu" in blob,
        "max_pool": "max_pool" in blob,
    }


def _int8_or_float(int8: bool) -> nn.Module:
    core = YoloV3Tiny()
    core.eval()
    if int8:
        return quantize_int8(core)
    return core


def run_exports(
    out_dir: Path,
    sizes: Tuple[int, ...],
    *,
    int8: bool,
) -> List[dict[str, Any]]:
    out_dir.mkdir(parents=True, exist_ok=True)
    reports: List[dict[str, Any]] = []
    tag = "int8" if int8 else "float"
    core = _int8_or_float(int8)

    for size in sizes:
        x = torch.randn(1, 3, size, size)
        gm, backend = export_module(core, (x,))
        payload = dump_graph(
            gm,
            backend,
            out_dir / f"graph_{tag}_{size}.txt",
            out_dir / f"graph_{tag}_{size}.json",
        )
        payload["kind"] = f"backbone_{tag}"
        payload["size"] = size
        payload["required"] = required_ops_present(payload["unique"])
        reports.append(payload)

        class _DetectDecode(nn.Module):
            def __init__(self, net: nn.Module, img_size: int) -> None:
                super().__init__()
                self.net = net
                self.decode = DecodeHeads(img_size)

            def forward(self, inp: torch.Tensor):
                d32, d16 = self.net(inp)
                return self.decode(d32, d16)

        try:
            wrapped = _DetectDecode(core, size)
            gm_d, backend_d = export_module(wrapped, (x,))
            payload_d = dump_graph(
                gm_d,
                backend_d,
                out_dir / f"graph_{tag}_{size}_decode.txt",
                out_dir / f"graph_{tag}_{size}_decode.json",
            )
            payload_d["kind"] = f"decode_{tag}"
            payload_d["size"] = size
            reports.append(payload_d)
        except Exception as exc:  # noqa: BLE001
            reports.append(
                {
                    "kind": f"decode_{tag}",
                    "size": size,
                    "error": str(exc).splitlines()[0],
                }
            )

    return reports


def run_exports_int32(
    out_dir: Path,
    sizes: Tuple[int, ...],
) -> List[dict[str, Any]]:
    """JIT integer module: int32 activations, custom conv / leaky."""
    out_dir.mkdir(parents=True, exist_ok=True)
    reports: List[dict[str, Any]] = []
    core: YoloV3TinyInt32 = quantize_int32(YoloV3Tiny()).eval()

    for size in sizes:
        x = torch.randint(-8, 9, (1, 3, size, size), dtype=torch.int32)
        gm, backend = export_module(core, (x,))
        payload = dump_graph(
            gm,
            backend,
            out_dir / f"graph_int32_{size}.txt",
            out_dir / f"graph_int32_{size}.json",
        )
        payload["kind"] = "backbone_int32"
        payload["size"] = size
        payload["required"] = required_ops_present(payload["unique"])
        reports.append(payload)

        class _DetectDecodeI32(nn.Module):
            def __init__(self, net: nn.Module, img_size: int) -> None:
                super().__init__()
                self.net = net
                self.decode = DecodeHeadsInt32(img_size)

            def forward(self, inp: torch.Tensor):
                d32, d16 = self.net(inp)
                return self.decode(d32, d16)

        try:
            wrapped = _DetectDecodeI32(core, size)
            gm_d, backend_d = export_module(wrapped, (x,))
            payload_d = dump_graph(
                gm_d,
                backend_d,
                out_dir / f"graph_int32_{size}_decode.txt",
                out_dir / f"graph_int32_{size}_decode.json",
            )
            payload_d["kind"] = "decode_int32"
            payload_d["size"] = size
            reports.append(payload_d)
        except Exception as exc:  # noqa: BLE001
            reports.append(
                {
                    "kind": "decode_int32",
                    "size": size,
                    "error": str(exc).splitlines()[0],
                }
            )

    return reports


def _export_letterbox(out_dir: Path) -> dict[str, Any]:
    lb = Letterbox(416)
    try:
        src = torch.randn(1, 3, 480, 640)
        gm_l, backend_l = export_module(lb, (src,))
        payload_l = dump_graph(
            gm_l,
            backend_l,
            out_dir / "graph_letterbox_480x640.txt",
            out_dir / "graph_letterbox_480x640.json",
        )
        payload_l["kind"] = "letterbox"
        return payload_l
    except Exception as exc:  # noqa: BLE001
        return {"kind": "letterbox", "error": str(exc).splitlines()[0]}


def _export_letterbox_int32(out_dir: Path) -> dict[str, Any]:
    lb = LetterboxInt32(32)
    try:
        src = torch.randint(0, 255, (1, 3, 24, 32), dtype=torch.int32)
        gm_l, backend_l = export_module(lb, (src,))
        payload_l = dump_graph(
            gm_l,
            backend_l,
            out_dir / "graph_letterbox_int32.txt",
            out_dir / "graph_letterbox_int32.json",
        )
        payload_l["kind"] = "letterbox_int32"
        return payload_l
    except Exception as exc:  # noqa: BLE001
        return {"kind": "letterbox_int32", "error": str(exc).splitlines()[0]}


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "graphs",
        help="Where to write graph_*.txt / .json",
    )
    parser.add_argument(
        "--sizes",
        type=int,
        nargs="+",
        default=[208, 416],
        help="Square input sizes to export",
    )
    parser.add_argument(
        "--float",
        action="store_true",
        help="Export the unfused float model as well as int8",
    )
    args = parser.parse_args(argv)

    all_reports: List[dict[str, Any]] = []
    all_reports.extend(run_exports(args.out_dir, tuple(args.sizes), int8=True))
    if args.float:
        all_reports.extend(run_exports(args.out_dir, tuple(args.sizes), int8=False))
    all_reports.extend(run_exports_int32(args.out_dir, tuple(args.sizes)))
    all_reports.append(_export_letterbox(args.out_dir))
    all_reports.append(_export_letterbox_int32(args.out_dir))
    all_reports.append(
        {
            "kind": "nms",
            "error": "not in the detector GraphModule; host NMS does not export "
            "(data-dependent keep count)",
        }
    )

    summary = args.out_dir / "ops_summary.txt"
    lines = ["# YOLOv3-Tiny exported call_function names", ""]
    for rep in all_reports:
        head = f"## {rep.get('kind')} size={rep.get('size', '-')}"
        lines.append(head)
        if "error" in rep:
            lines.append(f"ERROR: {rep['error']}")
        else:
            req = rep.get("required")
            if req:
                lines.append("required: " + ", ".join(f"{k}={v}" for k, v in req.items()))
            lines.append("unique:")
            for name in rep.get("unique", []):
                lines.append(f"  {name}")
        lines.append("")
    summary.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {summary}")
    for rep in all_reports:
        if "error" in rep:
            print(f"{rep.get('kind')} size={rep.get('size')}: ERROR {rep['error']}")
        elif rep.get("required"):
            print(f"{rep.get('kind')} size={rep.get('size')}: {rep['required']}")
        else:
            print(f"{rep.get('kind')}: {len(rep.get('unique', []))} unique ops")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
