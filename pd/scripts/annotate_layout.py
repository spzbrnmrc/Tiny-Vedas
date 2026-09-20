#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Dump hierarchical cell areas and paint CORE / VECTOR / GEMM on the die."""

from __future__ import annotations

import csv
import os
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

# 5x7 rows, '#' = pixel. Easy to eyeball.
_FONT: dict[str, tuple[str, ...]] = {
    " ": ("     ",) * 7,
    "/": (".   #", "   # ", "  #  ", "  #  ", " #   ", "#    ", "#    "),
    ".": ("     ", "     ", "     ", "     ", "     ", "  #  ", "  #  "),
    ",": ("     ", "     ", "     ", "     ", "  #  ", "  #  ", " #   "),
    "^": ("  #  ", " # # ", "#   #", "     ", "     ", "     ", "     "),
    "0": (" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "),
    "1": ("  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####"),
    "2": (" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"),
    "3": (" ### ", "#   #", "    #", "  ## ", "    #", "#   #", " ### "),
    "4": ("   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "),
    "5": ("#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "),
    "6": (" ### ", "#    ", "#    ", "#### ", "#   #", "#   #", " ### "),
    "7": ("#####", "    #", "   # ", "  #  ", "  #  ", "  #  ", "  #  "),
    "8": (" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "),
    "9": (" ### ", "#   #", "#   #", " ####", "    #", "    #", " ### "),
    "A": (" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"),
    "C": (" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "),
    "E": ("#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"),
    "G": (" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ### "),
    "I": ("#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####"),
    "L": ("#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"),
    "M": ("#   #", "## ##", "# # #", "#   #", "#   #", "#   #", "#   #"),
    "N": ("#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"),
    "O": (" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
    "P": ("#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "),
    "R": ("#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"),
    "S": (" ### ", "#   #", "#    ", " ### ", "    #", "#   #", " ### "),
    "T": ("#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "),
    "U": ("#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
    "V": ("#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "),
    "c": ("     ", "     ", " ### ", "#    ", "#    ", "#    ", " ### "),
    "e": ("     ", "     ", " ### ", "#   #", "#####", "#    ", " ### "),
    "l": (" #   ", " #   ", " #   ", " #   ", " #   ", " #   ", " ### "),
    "m": ("     ", "     ", "## # ", "# # #", "# # #", "#   #", "#   #"),
    "s": ("     ", "     ", " ### ", "#    ", " ### ", "    #", "#### "),
    "u": ("     ", "     ", "#   #", "#   #", "#   #", "#   #", " ####"),
}

_REPO = Path(__file__).resolve().parents[2]
_ACTIVE_MK = _REPO / "pd" / "active.mk"
_DUMP_TCL = Path(__file__).resolve().parent / "dump_hier_cells.tcl"
_DESIGN_NICKNAME = "tiny_vedas"
_DESIGN_VARIANT = "base"

_COLORS = {
    "CORE": (244, 196, 48),
    "VECTOR": (232, 93, 117),
    "GEMM": (0, 191, 255),
    "OTHER": (136, 136, 136),
}
_BG = (8, 8, 8)
_CANVAS = 2200
_MARGIN = 80


def _load_active_mk() -> dict[str, str]:
    if not _ACTIVE_MK.exists():
        print(f"error: {_ACTIVE_MK} not found — run 'make config' first", file=sys.stderr)
        sys.exit(1)
    env: dict[str, str] = {}
    for line in _ACTIVE_MK.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("export "):
            continue
        key, _, value = line.removeprefix("export ").partition("=")
        env[key.strip()] = value.strip().strip('"')
    return env


def _results_dir(env: dict[str, str]) -> Path:
    platform = env.get("PD_ORFS_PLATFORM") or env.get("PD_PLATFORM", "asap7")
    work_home = Path(env.get("ORFS_WORK_HOME", _REPO / "pd" / "work" / "orfs"))
    text = str(work_home)
    if text.startswith("/work/"):
        work_home = _REPO / text[len("/work/") :]
    return work_home / "results" / platform / _DESIGN_NICKNAME / _DESIGN_VARIANT


def _find_odb(results: Path) -> Path | None:
    for name in ("6_final.odb", "6_1_fill.odb", "5_2_route.odb"):
        cand = results / name
        if cand.is_file():
            return cand
    hits = sorted(results.glob("*.odb"))
    return hits[-1] if hits else None


def _find_openroad(env: dict[str, str]) -> str:
    exe = shutil.which("openroad")
    if exe:
        return exe
    orfs = Path(env.get("ORFS_ROOT", "/tools/OpenROAD-flow-scripts"))
    for cand in (
        orfs / "tools" / "install" / "OpenROAD" / "bin" / "openroad",
        Path("/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/openroad"),
    ):
        if cand.is_file():
            return str(cand)
    print("error: openroad not on PATH", file=sys.stderr)
    sys.exit(1)


def _dump_cells(env: dict[str, str], odb: Path, cells_csv: Path) -> None:
    openroad = _find_openroad(env)
    envp = os.environ.copy()
    envp.setdefault("QT_QPA_PLATFORM", "offscreen")
    envp["PD_ANNOTATE_ODB"] = str(odb)
    envp["PD_ANNOTATE_CELLS"] = str(cells_csv)
    proc = subprocess.run(
        [openroad, "-exit", "-no_splash", str(_DUMP_TCL)],
        env=envp,
        check=False,
    )
    if proc.returncode != 0 or not cells_csv.is_file():
        sys.exit(proc.returncode or 1)


def _write_png(path: Path, width: int, height: int, rgb: bytearray) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = bytearray()
    row = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(rgb[y * row : (y + 1) * row])
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def _paint(cells_csv: Path, png: Path, hier: Path) -> None:
    stats: dict[str, dict[str, float]] = {
        lab: {"n": 0, "area": 0.0} for lab in _COLORS
    }
    boxes: list[tuple[str, float, float, float, float]] = []
    xmin = ymin = 1e30
    xmax = ymax = -1e30
    with cells_csv.open(encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            lab = row["label"]
            if lab not in _COLORS:
                continue
            x0, y0, x1, y1 = (float(row[k]) for k in ("x0", "y0", "x1", "y1"))
            area = float(row["area_um2"])
            stats[lab]["n"] += 1
            stats[lab]["area"] += area
            boxes.append((lab, x0, y0, x1, y1))
            xmin = min(xmin, x0)
            ymin = min(ymin, y0)
            xmax = max(xmax, x1)
            ymax = max(ymax, y1)

    hier.write_text(
        "module,cell_area_um2,hier_cells\n"
        + "".join(
            f"{lab},{stats[lab]['area']:.4f},{int(stats[lab]['n'])}\n"
            for lab in ("CORE", "VECTOR", "GEMM", "OTHER")
        ),
        encoding="utf-8",
    )

    span = max(xmax - xmin, ymax - ymin, 1.0)
    scale = (_CANVAS - 2 * _MARGIN) / span
    height = _CANVAS + 160
    rgb = bytearray(_BG * _CANVAS * height)
    rowb = _CANVAS * 3

    def px(x: float, y: float) -> tuple[int, int]:
        c = int(_MARGIN + (x - xmin) * scale)
        r = int(_MARGIN + (ymax - y) * scale)
        return c, r

    def put(c: int, r: int, color: tuple[int, int, int]) -> None:
        if 0 <= c < _CANVAS and 0 <= r < height:
            i = r * rowb + c * 3
            rgb[i : i + 3] = bytes(color)

    for lab, x0, y0, x1, y1 in boxes:
        color = _COLORS[lab]
        c0, r1 = px(x0, y0)
        c1, r0 = px(x1, y1)
        if c1 < c0:
            c0, c1 = c1, c0
        if r1 < r0:
            r0, r1 = r1, r0
        if c1 == c0:
            c1 = c0 + 1
        if r1 == r0:
            r1 = r0 + 1
        for r in range(r0, min(r1, height)):
            for c in range(c0, min(c1, _CANVAS)):
                put(c, r, color)

    def draw_text(x: int, y: int, text: str, color: tuple[int, int, int]) -> None:
        scale = 3
        cx = x
        for ch in text:
            glyph = _FONT.get(ch, _FONT[" "])
            for row, line in enumerate(glyph):
                for col, pix in enumerate(line):
                    if pix == "#":
                        for dy in range(scale):
                            for dx in range(scale):
                                put(cx + col * scale + dx, y + row * scale + dy, color)
            cx += 6 * scale

    draw_text(20, 20, "CORE GEMM TOP ASAP7   CORE / VECTOR / GEMM", (220, 220, 220))
    legend_y = _CANVAS + 28
    x = _MARGIN
    for lab in ("CORE", "VECTOR", "GEMM"):
        for r in range(legend_y, legend_y + 18):
            for c in range(x, x + 18):
                put(c, r, _COLORS[lab])
        n = int(stats[lab]["n"])
        area = stats[lab]["area"]
        draw_text(x + 28, legend_y, f"{lab} {n} cells {area:.1f} um^2", (220, 220, 220))
        x += 700

    _write_png(png, _CANVAS, height, rgb)
    print(hier.read_text(encoding="utf-8"), end="")
    print(f"Wrote: {png}")
    print(f"Wrote: {hier}")


def main() -> int:
    env = _load_active_mk()
    out_dir = _REPO / "pd" / "work" / "layout"
    out_dir.mkdir(parents=True, exist_ok=True)
    cells_csv = out_dir / "cells_core_gemm_vector.csv"
    png = out_dir / "annotated_core_gemm_vector.png"
    hier = out_dir / "hier_area.csv"

    if cells_csv.is_file() and os.environ.get("PD_ANNOTATE_REPAINT") == "1":
        print(f"==> repaint from {cells_csv}")
        _paint(cells_csv, png, hier)
        return 0

    results = _results_dir(env)
    odb = _find_odb(results)
    if odb is None:
        print(
            f"error: no ORFS odb under {results} — run 'make rtl2gds' through finish",
            file=sys.stderr,
        )
        return 1

    print(f"==> dump cells from {odb}")
    _dump_cells(env, odb, cells_csv)
    _paint(cells_csv, png, hier)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
