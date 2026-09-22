# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Time JIT-generated STREAM nests on the x86 host (im2col+pack pole)."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import torch
import torch.nn as nn

_REPO = Path(__file__).resolve().parents[2]
_PYVEDAS = _REPO / "pyvedas"
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from conv_op import conv2d  # noqa: E402
from jit.compile import compile_model  # noqa: E402


class _C12(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.register_buffer(
            "weight",
            torch.randint(-2, 3, (256, 128, 3, 3), dtype=torch.int32),
        )
        self.register_buffer("bias", torch.zeros(256, dtype=torch.int32))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return conv2d(x, self.weight, self.bias, 1, 1)


def _gcc_host(generated: Path, bin_path: Path) -> None:
    obj = bin_path.with_suffix(".o")
    inc = [
        "-I",
        str(_PYVEDAS / "runtime" / "include"),
        "-I",
        str(_REPO / "sw" / "include"),
    ]
    subprocess.run(
        [
            "gcc",
            "-std=c11",
            "-O0",
            *inc,
            "-DSOC_DEFINES_H",
            "-DDRAM_BASE=((uintptr_t)host_dram)",
            "-DDRAM_BYTES=0x01000000",
            "-include",
            str(_REPO / "tests" / "unit" / "host_nolog.h"),
            "-Dmain=generated_main",
            "-c",
            str(generated),
            "-o",
            str(obj),
        ],
        check=True,
    )
    subprocess.run(
        [
            "gcc",
            "-std=c11",
            "-O0",
            *inc,
            "-o",
            str(bin_path),
            str(obj),
            str(_REPO / "tests" / "unit" / "host_stream_time.c"),
            str(_REPO / "tests" / "unit" / "host_gemm_dummy.c"),
            str(_PYVEDAS / "runtime" / "c" / "pyvedas_conv2d.c"),
            str(_PYVEDAS / "runtime" / "c" / "pyvedas_memcpy.c"),
        ],
        check=True,
    )


def _time_nest(nest: str, work: Path) -> float:
    os.environ["PYVEDAS_STREAM_NEST"] = nest
    try:
        x = torch.randint(-8, 9, (1, 128, 6, 6), dtype=torch.int32)
        compile_model(
            _C12().eval(),
            (x,),
            _PYVEDAS,
            work / nest,
            target=False,
            stream=True,
            goldens=False,
        )
    finally:
        os.environ.pop("PYVEDAS_STREAM_NEST", None)
    generated = work / nest / "generated.c"
    bin_path = work / f"host_{nest}"
    _gcc_host(generated, bin_path)
    out = subprocess.check_output([str(bin_path)], text=True)
    for line in out.splitlines():
        if line.startswith("host_s="):
            return float(line.split("=", 1)[1])
    raise RuntimeError(f"no host_s in {out!r}")


class TestGeneratedNestHostTimes(unittest.TestCase):
    def test_cache_col_is_fastest_generated_c(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            work = Path(td)
            times = {
                nest: _time_nest(nest, work)
                for nest in ("oc_outer", "spatial_outer", "cache_col")
            }
        self.assertLess(times["cache_col"], times["spatial_outer"])
        self.assertLess(times["spatial_outer"], times["oc_outer"])
        print(
            "generated c12 analog -O0 dummy GEMM: "
            + " ".join(f"{k}={v:.4f}s" for k, v in times.items()),
            flush=True,
        )


if __name__ == "__main__":
    unittest.main()
