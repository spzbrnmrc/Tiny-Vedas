#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""
Automated Slice B smoke on Alveo U280.

  sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py
  sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py --prog uart
  sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py --bin path/to/image.bin

Requires: Slice B bitstream programmed (VERSION 0x000B0010, BAR2 128 KiB),
PCIe enumerated, root for BAR mmap. qdma-pf may be loaded or not.
"""

from __future__ import annotations

import argparse
import struct
import sys
import time
from pathlib import Path

# Allow `python3 scripts/fpga_smoke.py` without PYTHONPATH
sys.path.insert(0, str(Path(__file__).resolve().parent))

from vedas_host import (  # noqa: E402
    ICCM_BASE,
    LINK_BASE,
    REG_HEARTBEAT,
    REG_SCRATCH,
    VERSION_SLICE_B,
    VedasBar2,
)

# Minimal RV32IM @ 0x00100000 — write DEADBEEF to 0x10000000, then spin.
# Assembled with: riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -Wl,-Ttext=0x100000
EOT_WORDS = [
    0x10000FB7,  # lui  t6, 0x10000
    0xDEADCF37,  # lui  t5, 0xDEADC
    0xEEFF0F13,  # addi t5, t5, -273   # t5 = 0xDEADBEEF
    0x01EFA023,  # sw   t5, 0(t6)
    0x0000006F,  # j    .
]

PREBUILT = Path(__file__).resolve().parent.parent / "sw" / "prebuilt"


def words_to_bytes(words: list[int]) -> bytes:
    return b"".join(struct.pack("<I", w & 0xFFFFFFFF) for w in words)


def load_bin(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description="Tiny-Vedas Alveo U280 Slice B smoke")
    ap.add_argument("--bdf", help="PCI BDF (default: first 10ee:903f)")
    ap.add_argument(
        "--prog",
        choices=("eot", "uart"),
        default="eot",
        help="Built-in program (default: eot)",
    )
    ap.add_argument("--bin", type=Path, help="Raw little-endian image linked at 0x00100000")
    ap.add_argument("--reset-vector", type=lambda x: int(x, 0), default=LINK_BASE)
    ap.add_argument("--timeout", type=float, default=2.0, help="EOT poll timeout (s)")
    ap.add_argument("--skip-run", action="store_true", help="Only check CTRL / load, no run")
    args = ap.parse_args()

    print(f"[fpga_smoke] opening BAR2 ({args.bdf or 'auto'})")
    with VedasBar2(bdf=args.bdf) as bar:
        print(f"[fpga_smoke] {bar.bdf} BAR2 size=0x{bar.size:x}")
        bar.require_bar_size()

        ver = bar.version()
        print(f"[fpga_smoke] VERSION=0x{ver:08x}")
        if ver != VERSION_SLICE_B:
            print(
                f"[fpga_smoke] ERROR: expected VERSION 0x{VERSION_SLICE_B:08x} "
                f"(Slice B). Program work/tiny_vedas_u280.bit and rescan PCIe.",
                file=sys.stderr,
            )
            return 2

        hb0 = bar.read32(REG_HEARTBEAT)
        time.sleep(0.01)
        hb1 = bar.read32(REG_HEARTBEAT)
        print(f"[fpga_smoke] HEARTBEAT {hb0} -> {hb1}")
        if hb1 == hb0:
            print("[fpga_smoke] ERROR: HEARTBEAT not advancing", file=sys.stderr)
            return 3

        bar.write32(REG_SCRATCH, 0xA5A55A5A)
        got = bar.read32(REG_SCRATCH)
        if got != 0xA5A55A5A:
            print(f"[fpga_smoke] ERROR: SCRATCH got 0x{got:08x}", file=sys.stderr)
            return 4
        print("[fpga_smoke] SCRATCH OK")

        bar.wait_mmcm_locked()
        print("[fpga_smoke] MMCM locked")

        bar.halt()
        print("[fpga_smoke] core halted")

        if args.bin:
            image = load_bin(args.bin)
            label = str(args.bin)
        elif args.prog == "uart":
            image = load_bin(PREBUILT / "uart_eot_smoke.bin")
            label = "prebuilt:uart_eot_smoke"
        else:
            image = words_to_bytes(EOT_WORDS)
            label = "builtin:eot"

        print(f"[fpga_smoke] loading {label} ({len(image)} bytes) @ ICCM")
        # Zero first page then write image
        bar.write_bytes(ICCM_BASE, b"\x00" * max(len(image), 64))
        bar.load_iccm(image, link_addr=LINK_BASE)

        # Readback first word
        w0 = bar.read32(ICCM_BASE)
        print(f"[fpga_smoke] ICCM[0]=0x{w0:08x}")

        bar.set_reset_vector(args.reset_vector)
        print(f"[fpga_smoke] reset_vector=0x{args.reset_vector:08x}")

        if args.skip_run:
            print("[fpga_smoke] --skip-run: done")
            return 0

        elapsed = bar.run_and_wait_eot(timeout_s=args.timeout)
        uart = bar.pop_uart()
        bar.halt()

        print(f"[fpga_smoke] EOT after {elapsed*1e3:.2f} ms")
        if uart:
            text = uart.decode("utf-8", errors="replace")
            print(f"[fpga_smoke] UART ({len(uart)} bytes): {text!r}")
        else:
            print("[fpga_smoke] UART empty")

        print("[fpga_smoke] PASS")
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PermissionError:
        print("[fpga_smoke] need root for BAR mmap (sudo)", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[fpga_smoke] FAIL: {e}", file=sys.stderr)
        # Best-effort UART dump after timeout / other errors
        try:
            with VedasBar2(bdf=None) as bar:
                uart = bar.pop_uart()
                if uart:
                    print(
                        f"[fpga_smoke] UART on fail ({len(uart)} bytes): "
                        f"{uart.decode('utf-8', errors='replace')!r}",
                        file=sys.stderr,
                    )
                bar.halt()
        except Exception:
            pass
        sys.exit(1)
