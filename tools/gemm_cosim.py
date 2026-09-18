#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Directed + random co-sim for gemm_top (XSim)."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]


def _run(cmd: str, cwd: Path | None = None) -> str:
    print(cmd)
    r = subprocess.run(
        cmd,
        shell=True,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        raise SystemExit(r.returncode)
    return r.stdout


def compile_tb(work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    proj = _REPO
    inc = f"-i {proj}/rtl/include -i {proj}/rtl/idu"
    srcs = " ".join(
        [
            f"{proj}/SVLib/src/registers_regfiles/register.sv",
            f"{proj}/SVLib/src/arith/ha.sv",
            f"{proj}/SVLib/src/arith/fa.sv",
            f"{proj}/SVLib/src/arith/cla_4.sv",
            f"{proj}/SVLib/src/arith/adder.sv",
            f"{proj}/SVLib/src/arith/csa_3_2.sv",
            f"{proj}/SVLib/src/arith/csa_4_2.sv",
            f"{proj}/SVLib/src/arith/booth_encoder.sv",
            f"{proj}/SVLib/src/arith/adder_pipe.sv",
            f"{proj}/SVLib/src/arith/kogge_stone_adder.sv",
            f"{proj}/SVLib/src/arith/mul.sv",
            f"{proj}/rtl/accel/gemm_pe.sv",
            f"{proj}/rtl/accel/gemm_datapath.sv",
            f"{proj}/rtl/accel/gemm_csr.sv",
            f"{proj}/rtl/accel/gemm_dma.sv",
            f"{proj}/rtl/accel/gemm_top.sv",
            f"{proj}/dv/sv/gemm_top_tb.sv",
        ]
    )
    _run(f"xvlog -sv {inc} {srcs}", cwd=work)
    _run(
        "xelab -top gemm_top_tb -snapshot gemm_sim --debug typical "
        "--timescale 1ns/1ps",
        cwd=work,
    )


def run_sim(work: Path, plusargs: list[str]) -> str:
    flags = " ".join(f"-testplusarg {a}" for a in plusargs)
    return _run(f"xsim gemm_sim --runall {flags}", cwd=work)


def _parse_cycles(text: str) -> int:
    cyc = 0
    for line in text.splitlines():
        if line.startswith("CASE"):
            for tok in line.split():
                if tok.startswith("cycles="):
                    cyc = int(tok.split("=")[1])
    return cyc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--directed", action="store_true")
    ap.add_argument("--random", action="store_true")
    ap.add_argument("--perf", action="store_true")
    ap.add_argument("--seeds", type=int, default=100)
    args = ap.parse_args()

    work = _REPO / "work" / "gemm_top"
    compile_tb(work)

    if args.directed or (not args.random and not args.perf):
        run_sim(work, ["directed"])

    if args.random:
        dims = (8, 32, 64, 128)
        for dim in dims:
            run_sim(
                work,
                [f"M={dim}", f"N={dim}", f"K={dim}", f"NSEED={args.seeds}"],
            )

    if args.perf:
        lines = ["size cycles macs peak_macs_at_64mac/cyc util"]
        peak = 64.0  # 8x8 MACs/cycle
        for dim in (32, 64, 128, 256):
            text = run_sim(
                work, [f"M={dim}", f"N={dim}", f"K={dim}", "SEED=1"]
            )
            log = work / f"perf_{dim}.log"
            log.write_text(text, encoding="utf-8")
            cyc = _parse_cycles(text)
            macs = dim * dim * dim
            util = (macs / (cyc * peak)) if cyc else 0.0
            lines.append(f"{dim} {cyc} {macs} {int(cyc * peak)} {util:.4f}")
        out = work / "perf_table.txt"
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(out.read_text())

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
