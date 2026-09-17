#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate SoC MMIO map (mmio_map.svh) and software defines from YAML."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO))

from hw.load import load_hw_config  # noqa: E402
from hw.soc_config import write_soc_artifacts  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--hw",
        default=str(_REPO / "hw" / "presets" / "rv32im_scalar.yaml"),
        help="Hardware preset YAML (selects the SoC map via `soc:`)",
    )
    parser.add_argument(
        "--mmio-svh",
        default=str(_REPO / "rtl" / "include" / "mmio_map.svh"),
        help="Output SystemVerilog MMIO map header",
    )
    parser.add_argument(
        "--soc-h",
        default=str(_REPO / "sw" / "include" / "soc_defines.h"),
        help="Output C SoC defines header",
    )
    parser.add_argument(
        "--soc-inc",
        default=str(_REPO / "sw" / "include" / "soc_defines.inc"),
        help="Output assembler SoC defines include",
    )
    args = parser.parse_args()

    hw = load_hw_config(args.hw)
    write_soc_artifacts(
        hw,
        mmio_svh=args.mmio_svh,
        soc_h=args.soc_h,
        soc_inc=args.soc_inc,
    )
    print(f"HW preset: {hw.name}")
    print(f"SoC map:   {hw.soc.name} ({hw.soc.source_path})")
    print(f"Wrote: {args.mmio_svh}")
    print(f"Wrote: {args.soc_h}")
    print(f"Wrote: {args.soc_inc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
