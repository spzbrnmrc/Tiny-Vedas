#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""
Slice C — run sim tests on Alveo U280 over PCIe.

  sudo ./venv/bin/python fpga/alveo_u280/scripts/fpga_runner.py -n c.helloworld
  sudo ./venv/bin/python fpga/alveo_u280/scripts/fpga_runner.py -t tests/smoke.tlist
  sudo ./venv/bin/python fpga/alveo_u280/scripts/fpga_runner.py -t tests/smoke.tlist --skip-oversized

Reuses tools/sim_manager.run_gen for compile/_start; loads .text→ICCM and
.data/.rodata/.bss→DCCM (same layout as prepare_imem). Pass = EOT within
timeout (+ UART golden when defined). Sim keeps ISS/retire TRACE.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from elftools.elf.elffile import ELFFile

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

from hw import default_hw_config_path, load_hw_config  # noqa: E402
from tools.sim_manager import read_task_list, run_gen  # noqa: E402

from vedas_host import (  # noqa: E402
    DCCM_BASE,
    DCCM_SIZE,
    ICCM_BASE,
    ICCM_SIZE,
    LINK_BASE,
    REG_HEARTBEAT,
    REG_SCRATCH,
    VERSION_SLICE_B,
    VedasBar2,
)

# BAR2 windows (board.yaml)
ICCM_BYTES = ICCM_SIZE
DCCM_BYTES = DCCM_SIZE
LINK_BASE_OFFSET = 0x00100000

DATA_SECTIONS = (".data", ".rodata", ".bss", ".sdata", ".init_array", ".fini_array")

# Known UART goldens (when --no-uart-check is not set)
UART_GOLDEN = {
    "c.helloworld": b"Hello, World!\nNumber is 100\n",
}

# VAX MIPS reference used by classic Dhrystone 2.1 DMIPS reporting
DHRYSTONE_VAX_MIPS = 1757.0


@dataclass
class DhryMetrics:
    runs: int
    dhrystones_per_sec: float
    dmips: float
    source: str  # "uart" or "host"


def parse_dhrystone_metrics(uart: bytes, elapsed_s: float) -> Optional[DhryMetrics]:
    """Extract Dhrystone rate from UART if present; else from host EOT time.

    The on-card UART mailbox is only 256 bytes, so the trailing
    \"Dhrystones per Second\" lines are often dropped. Host EOT wall time
    with the printed run count is then the authoritative figure (and better
    than the ELF's gettimeofday, which is an unimplemented ecall stub).
    """
    text = uart.decode("utf-8", errors="replace")
    runs = 2000
    m = re.search(r"Execution starts,\s*(\d+)\s+runs", text)
    if m:
        runs = int(m.group(1))

    m = re.search(r"Dhrystones\s+per\s+Second:\s*([0-9]+(?:\.[0-9]+)?)", text)
    if m and float(m.group(1)) > 0:
        dps = float(m.group(1))
        return DhryMetrics(runs, dps, dps / DHRYSTONE_VAX_MIPS, "uart")

    if elapsed_s <= 0:
        return None
    dps = runs / elapsed_s
    return DhryMetrics(runs, dps, dps / DHRYSTONE_VAX_MIPS, "host")


@dataclass
class FpgaImage:
    name: str
    reset_vector: int
    iccm: bytes
    dccm: bytes  # full DCCM_BYTES image (zeros + sections)


@dataclass
class RunResult:
    name: str
    ok: bool
    elapsed_s: float = 0.0
    uart: bytes = b""
    error: Optional[str] = None
    skipped: bool = False


class ImageTooLarge(RuntimeError):
    pass


def elf_to_fpga_image(elf_path: Path, name: str, reset_vector: int) -> FpgaImage:
    with elf_path.open("rb") as f:
        elf = ELFFile(f)
        text = elf.get_section_by_name(".text")
        if text is None:
            raise RuntimeError(f"{name}: no .text section")
        text_addr = text.header["sh_addr"]
        iccm = text.data()
        if text_addr not in (LINK_BASE_OFFSET, LINK_BASE, 0x100000):
            raise RuntimeError(
                f"{name}: .text @ 0x{text_addr:x}, expected 0x{LINK_BASE:x}"
            )
        if len(iccm) > ICCM_BYTES:
            raise ImageTooLarge(
                f"{name}: .text is {len(iccm)} bytes > ICCM {ICCM_BYTES}"
            )

        dccm = bytearray(DCCM_BYTES)
        for secname in DATA_SECTIONS:
            sec = elf.get_section_by_name(secname)
            if sec is None or sec.header["sh_size"] == 0:
                continue
            base = sec.header["sh_addr"] - LINK_BASE_OFFSET
            data = sec.data()
            # .bss (NOBITS) often has empty file contents — zero-fill to sh_size
            if len(data) < sec.header["sh_size"]:
                data = data + b"\x00" * (sec.header["sh_size"] - len(data))
            if base < 0 or base >= DCCM_BYTES:
                raise ImageTooLarge(
                    f"{name}: {secname} @ 0x{sec.header['sh_addr']:x} "
                    f"(dccm off 0x{base:x}) outside {DCCM_BYTES:#x} window"
                )
            end = base + len(data)
            if end > DCCM_BYTES:
                raise ImageTooLarge(
                    f"{name}: {secname} spills DCCM "
                    f"({len(data)} bytes @ off 0x{base:x})"
                )
            dccm[base:end] = data

    return FpgaImage(
        name=name,
        reset_vector=reset_vector,
        iccm=iccm,
        dccm=bytes(dccm),
    )


def prepare_test(test: str, hw_config) -> FpgaImage:
    os.chdir(_REPO_ROOT)
    reset_vector = run_gen(test, hw_config)
    elf_path = _REPO_ROOT / "work" / test / "test.elf"
    if not elf_path.is_file():
        raise RuntimeError(f"{test}: missing {elf_path}")
    return elf_to_fpga_image(elf_path, test, reset_vector)


def check_ctrl(bar: VedasBar2) -> None:
    bar.require_bar_size()
    ver = bar.version()
    if ver != VERSION_SLICE_B:
        raise RuntimeError(
            f"VERSION 0x{ver:08x} != 0x{VERSION_SLICE_B:08x} — program Slice B bit"
        )
    hb0 = bar.read32(REG_HEARTBEAT)
    time.sleep(0.01)
    hb1 = bar.read32(REG_HEARTBEAT)
    if hb1 == hb0:
        raise RuntimeError("HEARTBEAT not advancing")
    bar.write32(REG_SCRATCH, 0xA5A55A5A)
    if bar.read32(REG_SCRATCH) != 0xA5A55A5A:
        raise RuntimeError("SCRATCH R/W failed")
    bar.wait_mmcm_locked()


def load_and_run(
    bar: VedasBar2,
    img: FpgaImage,
    *,
    timeout_s: float,
    expect_uart: Optional[bytes] = None,
) -> RunResult:
    bar.halt()
    bar.write_bytes(ICCM_BASE, b"\x00" * ICCM_BYTES)
    bar.write_bytes(DCCM_BASE, b"\x00" * DCCM_BYTES)
    bar.load_iccm(img.iccm, link_addr=LINK_BASE)
    bar.load_dccm(img.dccm, offset=0)
    bar.set_reset_vector(img.reset_vector)

    try:
        elapsed = bar.run_and_wait_eot(timeout_s=timeout_s)
    except TimeoutError as e:
        uart = bar.pop_uart()
        bar.halt()
        return RunResult(img.name, False, 0.0, uart, str(e))

    uart = bar.pop_uart()
    bar.halt()

    if expect_uart is not None and uart != expect_uart:
        return RunResult(
            img.name,
            False,
            elapsed,
            uart,
            f"UART mismatch: got {uart!r} want {expect_uart!r}",
        )

    return RunResult(img.name, True, elapsed, uart)


def main() -> int:
    ap = argparse.ArgumentParser(description="Tiny-Vedas FPGA Slice C test runner")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("-n", "--test", help="single test name (e.g. c.helloworld)")
    g.add_argument("-t", "--task-list", type=Path, help="task list file")
    ap.add_argument("--bdf", help="PCI BDF (default: first 10ee:903f)")
    ap.add_argument("--hw-config", default=default_hw_config_path())
    ap.add_argument("--timeout", type=float, default=5.0, help="EOT timeout per test (s)")
    ap.add_argument(
        "--skip-oversized",
        action="store_true",
        help="skip tests that do not fit 32 KiB ICCM / 64 KiB DCCM (default: fail them)",
    )
    ap.add_argument(
        "--expect-uart",
        type=str,
        default=None,
        help="exact UART string to require (overrides built-in goldens)",
    )
    ap.add_argument(
        "--no-uart-check",
        action="store_true",
        help="never compare UART (EOT-only pass)",
    )
    args = ap.parse_args()

    os.chdir(_REPO_ROOT)
    hw_config = load_hw_config(args.hw_config)

    if args.test:
        tests = [args.test]
    else:
        tests = read_task_list(str(args.task_list))

    results: list[RunResult] = []

    print(f"[fpga_runner] opening BAR2 ({args.bdf or 'auto'})")
    with VedasBar2(bdf=args.bdf) as bar:
        print(f"[fpga_runner] {bar.bdf} BAR2=0x{bar.size:x}")
        check_ctrl(bar)
        print(f"[fpga_runner] VERSION=0x{bar.version():08x} MMCM locked")

        for test in tests:
            print(f"[fpga_runner] === {test} ===")
            try:
                img = prepare_test(test, hw_config)
            except ImageTooLarge as e:
                msg = str(e)
                if args.skip_oversized:
                    print(f"[fpga_runner] SKIP oversized: {msg}")
                    results.append(RunResult(test, True, skipped=True, error=msg))
                    continue
                print(f"[fpga_runner] FAIL: {msg}", file=sys.stderr)
                results.append(RunResult(test, False, error=msg))
                continue
            except Exception as e:
                print(f"[fpga_runner] FAIL prepare: {e}", file=sys.stderr)
                results.append(RunResult(test, False, error=str(e)))
                continue

            expect: Optional[bytes] = None
            if not args.no_uart_check:
                if args.expect_uart is not None:
                    expect = args.expect_uart.encode("utf-8")
                else:
                    expect = UART_GOLDEN.get(test)

            print(
                f"[fpga_runner] load iccm={len(img.iccm)}B "
                f"dccm_nonzero={sum(1 for b in img.dccm if b)}B "
                f"reset=0x{img.reset_vector:08x}"
            )
            rr = load_and_run(
                bar,
                img,
                timeout_s=args.timeout,
                expect_uart=expect,
            )
            results.append(rr)
            if rr.ok:
                uart_s = rr.uart.decode("utf-8", errors="replace") if rr.uart else ""
                extra = ""
                if test == "elf.dhrystone":
                    m = parse_dhrystone_metrics(rr.uart, rr.elapsed_s)
                    if m is not None:
                        extra = (
                            f" runs={m.runs} dps={m.dhrystones_per_sec:,.0f} "
                            f"DMIPS={m.dmips:.2f} ({m.source})"
                        )
                print(
                    f"[fpga_runner] PASS {test} EOT={rr.elapsed_s*1e3:.2f}ms "
                    f"UART={uart_s!r}{extra}"
                )
            else:
                uart_s = rr.uart.decode("utf-8", errors="replace") if rr.uart else ""
                print(
                    f"[fpga_runner] FAIL {test}: {rr.error} UART={uart_s!r}",
                    file=sys.stderr,
                )

    passed = sum(1 for r in results if r.ok and not r.skipped)
    skipped = sum(1 for r in results if r.skipped)
    failed = sum(1 for r in results if not r.ok)
    print(
        f"[fpga_runner] summary: {passed} passed, {failed} failed, {skipped} skipped "
        f"(of {len(results)})"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PermissionError:
        print("[fpga_runner] need root for BAR mmap (sudo)", file=sys.stderr)
        raise SystemExit(1)
