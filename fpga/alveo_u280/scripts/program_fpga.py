#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""
Program Tiny-Vedas Alveo U280 bitstream over JTAG, then PCIe remove/rescan.

  # default bit: fpga/alveo_u280/work/tiny_vedas_u280.bit
  sudo python3 fpga/alveo_u280/scripts/program_fpga.py
  sudo python3 fpga/alveo_u280/scripts/program_fpga.py --bit path/to.bit
  sudo python3 fpga/alveo_u280/scripts/program_fpga.py --no-rescan
  make -C fpga/alveo_u280 program

Needs: Vivado 2023.2 on PATH, Alveo USB/JTAG, root for PCIe rescan / BAR verify.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

BOARD_DIR = Path(__file__).resolve().parent.parent
DEFAULT_BIT = BOARD_DIR / "work" / "tiny_vedas_u280.bit"
PROGRAM_TCL = BOARD_DIR / "tcl" / "program.tcl"

XILINX_VENDOR = 0x10EE
QDMA_DEVICE = 0x903F
QDMA_MODPROBE = "qdma-pf"


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    print(f"[program_fpga] + {' '.join(cmd)}")
    return subprocess.run(cmd, check=check)


def find_vivado() -> str:
    vivado = shutil.which("vivado")
    if vivado:
        return vivado
    # sudo often drops PATH; check common install + VIVADO env.
    candidates = [
        os.environ.get("VIVADO", ""),
        "/tools/Xilinx/Vivado/2023.2/bin/vivado",
        "/opt/Xilinx/Vivado/2023.2/bin/vivado",
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return c
    raise SystemExit(
        "error: vivado not found (source Vivado 2023.2 settings64.sh, or set VIVADO=)"
    )


def find_qdma_bdfs() -> list[str]:
    sysfs = Path("/sys/bus/pci/devices")
    out: list[str] = []
    if not sysfs.is_dir():
        return out
    for p in sorted(sysfs.iterdir()):
        try:
            vend = int((p / "vendor").read_text().strip(), 16)
            dev = int((p / "device").read_text().strip(), 16)
        except OSError:
            continue
        if vend == XILINX_VENDOR and dev == QDMA_DEVICE:
            out.append(p.name)
    return out


def write_sysfs(path: Path, value: str) -> None:
    path.write_text(value)


def unload_qdma() -> None:
    # Ignore failure if not loaded / in use.
    subprocess.run(["modprobe", "-r", QDMA_MODPROBE], check=False)


def load_qdma() -> None:
    run(["modprobe", QDMA_MODPROBE])


def pcie_remove_rescan(bdfs: list[str], settle_s: float) -> None:
    for bdf in bdfs:
        remove = Path(f"/sys/bus/pci/devices/{bdf}/remove")
        if remove.exists():
            print(f"[program_fpga] PCIe remove {bdf}")
            write_sysfs(remove, "1")
        else:
            print(f"[program_fpga] warn: missing {remove}")
    time.sleep(0.5)
    rescan = Path("/sys/bus/pci/rescan")
    print("[program_fpga] PCIe rescan")
    write_sysfs(rescan, "1")
    deadline = time.time() + settle_s
    while time.time() < deadline:
        found = find_qdma_bdfs()
        if found:
            print(f"[program_fpga] enumerated: {', '.join(found)}")
            return
        time.sleep(0.25)
    raise SystemExit(
        f"error: no {XILINX_VENDOR:04x}:{QDMA_DEVICE:04x} after rescan "
        f"(waited {settle_s:.0f}s)"
    )


def verify_version(expected: int | None) -> int:
    # Import after PATH/sysfs ready; needs root for mmap.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from vedas_host import VERSION_SLICE_B, VedasBar2  # noqa: WPS433

    want = expected if expected is not None else VERSION_SLICE_B
    with VedasBar2() as bar:
        bar.require_bar_size()
        ver = bar.version()
        print(f"[program_fpga] {bar.bdf} BAR2=0x{bar.size:x} VERSION=0x{ver:08x}")
        if ver != want:
            print(
                f"[program_fpga] ERROR: expected VERSION 0x{want:08x}",
                file=sys.stderr,
            )
            return 2
    print("[program_fpga] VERSION OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Program Alveo U280 Tiny-Vedas bitstream")
    ap.add_argument(
        "--bit",
        type=Path,
        default=DEFAULT_BIT,
        help=f"bitstream path (default: {DEFAULT_BIT})",
    )
    ap.add_argument(
        "--no-rescan",
        action="store_true",
        help="JTAG program only (skip driver unload / PCIe remove+rescan)",
    )
    ap.add_argument(
        "--no-driver",
        action="store_true",
        help="skip qdma-pf unload/reload (still rescans PCIe unless --no-rescan)",
    )
    ap.add_argument(
        "--settle",
        type=float,
        default=8.0,
        help="seconds to wait for PCIe re-enumeration (default: 8)",
    )
    ap.add_argument(
        "--verify",
        action="store_true",
        default=True,
        help="mmap BAR2 and check VERSION after rescan (default: on)",
    )
    ap.add_argument(
        "--no-verify",
        action="store_false",
        dest="verify",
        help="skip VERSION check",
    )
    ap.add_argument(
        "--expect-version",
        type=lambda x: int(x, 0),
        default=None,
        help="expected VERSION (default: vedas_host.VERSION_SLICE_B)",
    )
    ap.add_argument(
        "--log",
        type=Path,
        default=BOARD_DIR / "work" / "vivado_program.log",
        help="Vivado batch log path",
    )
    args = ap.parse_args()

    bit = args.bit.resolve()
    if not bit.is_file():
        raise SystemExit(f"error: bitstream not found: {bit}")
    if not PROGRAM_TCL.is_file():
        raise SystemExit(f"error: missing {PROGRAM_TCL}")

    if not args.no_rescan and os.geteuid() != 0:
        raise SystemExit(
            "error: PCIe rescan needs root — re-run with sudo, or pass --no-rescan"
        )

    vivado = find_vivado()
    args.log.parent.mkdir(parents=True, exist_ok=True)

    bdfs_before = find_qdma_bdfs()
    print(f"[program_fpga] PCI before: {bdfs_before or '(none)'}")

    if not args.no_rescan and not args.no_driver:
        print(f"[program_fpga] unloading {QDMA_MODPROBE}")
        unload_qdma()

    run(
        [
            vivado,
            "-mode",
            "batch",
            "-nojournal",
            "-log",
            str(args.log),
            "-source",
            str(PROGRAM_TCL),
            "-tclargs",
            str(bit),
        ]
    )

    if args.no_rescan:
        print("[program_fpga] programmed (skipped PCIe rescan)")
        return 0

    # Link may drop during config; brief settle before remove.
    time.sleep(1.0)
    bdfs = find_qdma_bdfs() or bdfs_before
    if not bdfs:
        # Device already gone — just rescan.
        print("[program_fpga] no PCI endpoint present; rescanning")
        write_sysfs(Path("/sys/bus/pci/rescan"), "1")
        deadline = time.time() + args.settle
        while time.time() < deadline and not find_qdma_bdfs():
            time.sleep(0.25)
        if not find_qdma_bdfs():
            raise SystemExit("error: no QDMA device after rescan")
    else:
        pcie_remove_rescan(bdfs, args.settle)

    if not args.no_driver:
        print(f"[program_fpga] loading {QDMA_MODPROBE}")
        load_qdma()

    if args.verify:
        # BAR mmap needs a short pause after driver bind.
        time.sleep(0.5)
        return verify_version(args.expect_version)

    print("[program_fpga] done")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as e:
        print(f"[program_fpga] command failed: {e}", file=sys.stderr)
        raise SystemExit(e.returncode or 1)
