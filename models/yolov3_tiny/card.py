# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Compile STREAM Tiny and run one frame on the U280 DRAM stub."""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

import torch
import torch.nn as nn

from .int32 import DecodeHeadsInt32, quantize_int32
from .model import YoloV3Tiny
from .post import detections_from_i32, letterbox
from .weights import load_darknet_weights

_REPO = Path(__file__).resolve().parents[2]
_FPGA_SCRIPTS = _REPO / "fpga" / "alveo_u280" / "scripts"
_PYVEDAS = _REPO / "pyvedas"
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))
if str(_FPGA_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_FPGA_SCRIPTS))

from hw import default_hw_config_path, load_hw_config  # noqa: E402
from hw.soc_config import write_soc_artifacts  # noqa: E402
from jit.compile import compile_model  # noqa: E402
from tools.sim_manager import _compile_riscv_elf  # noqa: E402
from fpga_runner import (  # noqa: E402
    ImageTooLarge,
    elf_symbol_addr,
    elf_to_fpga_image,
    parse_dram_hex,
)
from vedas_host import (  # noqa: E402
    DCCM_BASE,
    DCCM_SIZE,
    LINK_BASE,
    VERSION_SLICE_B,
    VedasBar2,
    find_qdma_bdf,
)

OP_LIMIT_SYM = "_pyvedas_op_limit"


def _cal_stamp(cal: Path | None) -> str:
    if cal is None:
        return "cal=none"
    path = cal.resolve()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
    return f"cal={path} sha256={digest}"


class _BackboneOnly(nn.Module):
    def __init__(self, backbone: nn.Module) -> None:
        super().__init__()
        self.backbone = backbone

    def forward(self, x: torch.Tensor):
        return self.backbone(x)


class _BackboneDecode(nn.Module):
    def __init__(self, backbone: nn.Module, decode: nn.Module) -> None:
        super().__init__()
        self.backbone = backbone
        self.decode = decode

    def forward(self, x: torch.Tensor):
        d32, d16 = self.backbone(x)
        return self.decode(d32, d16)


def card_available() -> bool:
    try:
        find_qdma_bdf()
        return True
    except Exception:
        return False


def _write_soc(hw) -> None:
    write_soc_artifacts(
        hw,
        mmio_svh=_REPO / "rtl" / "include" / "mmio_map.svh",
        soc_h=_REPO / "sw" / "include" / "soc_defines.h",
        soc_inc=_REPO / "sw" / "include" / "soc_defines.inc",
    )


def _quantize_input(image: torch.Tensor, size: int) -> Tuple[torch.Tensor, float, int, int, int, int]:
    _, h, w = image.shape
    canvas, scale, left, top = letterbox(image, size)
    canvas_i = torch.round(canvas * 255.0).clamp(0, 255).to(torch.int32) - 128
    canvas_i = canvas_i.clamp(-127, 127)
    return canvas_i, scale, left, top, h, w


def _link_elf(work_dir: Path, hw) -> None:
    manifest = json.loads((work_dir / "manifest.json").read_text(encoding="utf-8"))
    eot = _REPO / "tests" / "c" / "asm_functions" / "eot_sequence.s"
    sources = [manifest["generated_c"], str(eot), *manifest["sources"]]
    test_name = work_dir.name
    _compile_riscv_elf(test_name, sources, manifest["include_dirs"], hw)


def ensure_card_elf(
    *,
    size: int,
    weights: Path,
    work_dir: Path,
    decode_on_core: bool = True,
    cal: Path | None = None,
) -> Dict[str, Any]:
    """JIT + RISC-V link. Reuses work_dir when the ELF and manifest match."""
    os.chdir(_REPO)
    work_dir = work_dir.resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    stamp = work_dir / "card_stamp.txt"
    key = (
        f"size={size} weights={weights.resolve()} "
        f"decode={int(decode_on_core)} oplimit=1 {_cal_stamp(cal)}\n"
    )
    elf = work_dir / "test.elf"
    man = work_dir / "manifest.json"
    if elf.is_file() and man.is_file() and stamp.is_file() and stamp.read_text() == key:
        return json.loads(man.read_text(encoding="utf-8"))

    hw = load_hw_config(default_hw_config_path())
    _write_soc(hw)

    float_m = YoloV3Tiny()
    load_darknet_weights(float_m, weights)
    backbone = quantize_int32(float_m, requant=True, cal=cal).eval()
    dummy = torch.zeros(1, 3, size, size, dtype=torch.int32)
    if decode_on_core:
        model: nn.Module = _BackboneDecode(backbone, DecodeHeadsInt32(size))
    else:
        model = _BackboneOnly(backbone)

    compile_model(
        model,
        (dummy,),
        _PYVEDAS,
        work_dir,
        target=True,
        hw_config=hw,
        stream=True,
        goldens=False,
    )
    _link_elf(work_dir, hw)
    stamp.write_text(key, encoding="utf-8")
    return json.loads((work_dir / "manifest.json").read_text(encoding="utf-8"))


def _i32_from_dram(raw: bytes, shape: List[int]) -> torch.Tensor:
    t = torch.frombuffer(bytearray(raw), dtype=torch.int32)
    return t.reshape(tuple(int(d) for d in shape)).clone()


def detect_card(
    image: torch.Tensor,
    size: int,
    conf: float,
    iou: float,
    work_dir: Path,
    *,
    weights: Path,
    timeout_s: float = 90.0,
    cal: Path | None = None,
    decode_on_core: bool = True,
) -> Tuple[torch.Tensor, float]:
    """Run the streamed integer ELF on the U280 and host-NMS the heads."""
    if not card_available():
        raise RuntimeError(
            "No QDMA PF (10ee:903f). Program the zve32x+DRAM bit, then:\n"
            "  sudo python3 fpga/alveo_u280/scripts/program_fpga.py"
        )

    try:
        manifest = ensure_card_elf(
            size=size,
            weights=weights,
            work_dir=work_dir,
            decode_on_core=decode_on_core,
            cal=cal,
        )
        img = elf_to_fpga_image(work_dir / "test.elf", work_dir.name, LINK_BASE)
    except ImageTooLarge as exc:
        if not decode_on_core:
            raise
        print(f"decode-on-core failed ({exc}); backbone only", file=sys.stderr)
        bb_dir = work_dir.parent / f"{work_dir.name}_bb"
        manifest = ensure_card_elf(
            size=size,
            weights=weights,
            work_dir=bb_dir,
            decode_on_core=False,
            cal=cal,
        )
        img = elf_to_fpga_image(bb_dir / "test.elf", bb_dir.name, LINK_BASE)
        work_dir = bb_dir

    hw = load_hw_config(default_hw_config_path())
    dram_hex = work_dir / "dram.hex"
    if dram_hex.is_file():
        print(f"[card] parse {dram_hex} ({dram_hex.stat().st_size}B)", flush=True)
        img.dram = parse_dram_hex(dram_hex, hw.memory.dram_bytes)
        print(f"[card] dram image {len(img.dram)}B", flush=True)

    canvas_i, scale, left, top, h, w = _quantize_input(image, size)
    inputs = manifest.get("input_names") or []
    if not inputs:
        raise RuntimeError("manifest has no input_names")
    inp = manifest["buffers"][inputs[0]]
    payload = canvas_i.contiguous().cpu().view(-1).to(torch.int32).numpy().tobytes()
    if len(payload) != int(inp["numel"]) * int(inp["elem_bytes"]):
        raise RuntimeError(
            f"input {len(payload)}B != manifest {inp['numel']}*{inp['elem_bytes']}"
        )

    results = [manifest["buffers"][n] for n in manifest["result_names"]]

    with VedasBar2() as bar:
        if bar.version() != VERSION_SLICE_B:
            raise RuntimeError(
                f"VERSION 0x{bar.version():08x} != 0x{VERSION_SLICE_B:08x}"
            )
        if not bar.has_dram_window():
            raise RuntimeError(
                "This bitstream has no DRAM window (CTRL 0x28 is dead). "
                "Rebuild and program: make -C fpga/alveo_u280 bitstream && "
                "sudo python3 fpga/alveo_u280/scripts/program_fpga.py"
            )
        bar.halt()
        print(f"[card] load iccm={len(img.iccm)}B dccm={len(img.dccm)}B", flush=True)
        bar.load_iccm(img.iccm, link_addr=LINK_BASE)
        bar.load_dccm(img.dccm, offset=0)
        if img.dram:
            print(f"[card] load dram={len(img.dram)}B", flush=True)
            bar.load_dram(img.dram)
        print(f"[card] patch input {len(payload)}B @ {int(inp['offset']):#x}", flush=True)
        bar.load_dram_range(payload, int(inp["offset"]))
        bar.set_reset_vector(img.reset_vector)
        print(f"[card] run reset=0x{img.reset_vector:08x} eot_timeout={timeout_s:.0f}s", flush=True)
        elapsed = bar.run_and_wait_eot(timeout_s=timeout_s)
        bar.halt()
        tensors: List[torch.Tensor] = []
        for spec in results:
            raw = bar.read_dram(
                int(spec["numel"]) * int(spec["elem_bytes"]),
                offset=int(spec["offset"]),
                window=DCCM_SIZE,
            )
            tensors.append(_i32_from_dram(raw, spec["shape"]))

    if len(tensors) == 3:
        boxes, obj, cls = tensors
    elif len(tensors) == 2:
        decode = DecodeHeadsInt32(size)
        boxes, obj, cls = decode(tensors[0], tensors[1])
    else:
        raise RuntimeError(f"unexpected {len(tensors)} result buffers")

    det = detections_from_i32(
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
    return det, elapsed


def _prepare_card_image(
    *,
    size: int,
    weights: Path,
    work_dir: Path,
    decode_on_core: bool = True,
    cal: Path | None = None,
):
    try:
        manifest = ensure_card_elf(
            size=size,
            weights=weights,
            work_dir=work_dir,
            decode_on_core=decode_on_core,
            cal=cal,
        )
        img = elf_to_fpga_image(work_dir / "test.elf", work_dir.name, LINK_BASE)
        elf_path = work_dir / "test.elf"
    except ImageTooLarge as exc:
        print(f"decode-on-core failed ({exc}); backbone only", file=sys.stderr)
        bb_dir = work_dir.parent / f"{work_dir.name}_bb"
        manifest = ensure_card_elf(
            size=size,
            weights=weights,
            work_dir=bb_dir,
            decode_on_core=False,
            cal=cal,
        )
        img = elf_to_fpga_image(bb_dir / "test.elf", bb_dir.name, LINK_BASE)
        elf_path = bb_dir / "test.elf"
        work_dir = bb_dir

    hw = load_hw_config(default_hw_config_path())
    dram_hex = work_dir / "dram.hex"
    if dram_hex.is_file():
        print(f"[card] parse {dram_hex} ({dram_hex.stat().st_size}B)", flush=True)
        img.dram = parse_dram_hex(dram_hex, hw.memory.dram_bytes)
        print(f"[card] dram image {len(img.dram)}B", flush=True)
    return manifest, img, elf_path, work_dir


def run_card_chunks(
    *,
    size: int,
    weights: Path,
    work_dir: Path,
    start: int = 1,
    stop: int | None = None,
    timeout_s: float = 45.0,
    cal: Path | None = None,
) -> int:
    """Run ops 1..n → EOT, then 1..(n+1) → EOT, until stop or a hang."""
    if not card_available():
        raise RuntimeError("No QDMA PF (10ee:903f). Program the zve32x+DRAM bit.")

    manifest, img, elf_path, work_dir = _prepare_card_image(
        size=size,
        weights=weights,
        work_dir=work_dir,
        decode_on_core=False,
        cal=cal,
    )
    ops = list(manifest.get("ops") or [])
    if not ops:
        raise RuntimeError("manifest has no ops — rebuild the STREAM ELF")
    last = len(ops) if stop is None else min(int(stop), len(ops))
    first = max(1, int(start))
    limit_addr = elf_symbol_addr(elf_path, OP_LIMIT_SYM)
    dccm_off = limit_addr - LINK_BASE
    if dccm_off < 0 or dccm_off + 4 > DCCM_SIZE:
        raise RuntimeError(
            f"{OP_LIMIT_SYM} @ 0x{limit_addr:08x} is outside DCCM "
            f"(off {dccm_off})"
        )
    print(
        f"[chunk] {len(ops)} ops, run {first}..{last}, "
        f"{OP_LIMIT_SYM}=0x{limit_addr:08x} dccm+{dccm_off:#x}",
        flush=True,
    )
    for i, name in enumerate(ops, 1):
        print(f"[chunk]  {i:3d}  {name}", flush=True)

    with VedasBar2() as bar:
        if bar.version() != VERSION_SLICE_B:
            raise RuntimeError(
                f"VERSION 0x{bar.version():08x} != 0x{VERSION_SLICE_B:08x}"
            )
        if not bar.has_dram_window():
            raise RuntimeError("bitstream has no DRAM window")
        bar.halt()
        print(f"[card] load iccm={len(img.iccm)}B dccm={len(img.dccm)}B", flush=True)
        bar.load_iccm(img.iccm, link_addr=LINK_BASE)
        bar.load_dccm(img.dccm, offset=0)
        if img.dram:
            print(f"[card] load dram={len(img.dram)}B", flush=True)
            bar.load_dram(img.dram)

        for n in range(first, last + 1):
            bar.halt()
            bar.load_dccm(img.dccm, offset=0)
            bar.write_bytes(DCCM_BASE + dccm_off, n.to_bytes(4, "little"))
            bar.set_reset_vector(img.reset_vector)
            print(
                f"[chunk] run 1..{n} last={ops[n - 1]} timeout={timeout_s:.0f}s",
                flush=True,
            )
            try:
                elapsed = bar.run_and_wait_eot(timeout_s=timeout_s)
            except TimeoutError as exc:
                print(f"[chunk] FAIL {exc}", flush=True)
                return 1
            print(f"[chunk] EOT n={n} {elapsed*1e3:.1f}ms", flush=True)
    print(f"[chunk] all {first}..{last} reached EOT", flush=True)
    return 0


def chunk_main(argv: List[str] | None = None) -> int:
    import argparse

    from .weights import default_weights_path, download_weights

    parser = argparse.ArgumentParser(
        description="Card bring-up: first N STREAM ops, then EOT."
    )
    parser.add_argument("--size", type=int, default=208, choices=(208, 416))
    parser.add_argument("--weights", type=Path, default=None)
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="STREAM ELF directory (default work/yolo_card_<size>)",
    )
    parser.add_argument("--start", type=int, default=1)
    parser.add_argument("--stop", type=int, default=None)
    parser.add_argument("--eot-timeout", type=float, default=45.0)
    parser.add_argument(
        "--cal",
        type=Path,
        default=None,
        help="Requant calibration YAML (off = first-design requant)",
    )
    args = parser.parse_args(argv)
    weights = args.weights or default_weights_path()
    if not weights.is_file():
        weights = download_weights(weights)
    work_dir = (args.work_dir or Path(f"work/yolo_card_{args.size}")).resolve()
    return run_card_chunks(
        size=args.size,
        weights=weights,
        work_dir=work_dir,
        start=args.start,
        stop=args.stop,
        timeout_s=args.eot_timeout,
        cal=args.cal,
    )
