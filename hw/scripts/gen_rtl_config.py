#!/usr/bin/env python3
# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate rtl/include/hw_config.svh from a hardware preset YAML."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO))

from hw.load import load_hw_config  # noqa: E402
from hw.rtl_config import write_hw_config_svh  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--hw",
        default=str(_REPO / "hw" / "presets" / "rv32im_scalar.yaml"),
        help="Hardware preset YAML",
    )
    parser.add_argument(
        "--out",
        default=str(_REPO / "rtl" / "include" / "hw_config.svh"),
        help="Output SystemVerilog header path",
    )
    args = parser.parse_args()

    hw = load_hw_config(args.hw)
    out_path = Path(args.out)
    write_hw_config_svh(out_path, hw)
    print(f"HW preset: {hw.name}")
    print(f"Wrote: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
