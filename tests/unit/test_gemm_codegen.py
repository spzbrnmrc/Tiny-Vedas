# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Compiler GEMM tiling is decided in Python and baked into generated C."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
_PYVEDAS = _REPO / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from jit.codegen_handlers import emit_gemm_c  # noqa: E402
from jit.memory.gemm_tiles import tile_scratch_bytes  # noqa: E402


class TestCompilerGemmTiling(unittest.TestCase):
    def test_one_shot_rank2(self) -> None:
        text = emit_gemm_c(
            "pyvedas_gemm_job", "a", "b", "c", (8, 8), (8, 8), 128 * 1024
        )
        self.assertIn("const size_t mt = 8;", text)
        self.assertIn(
            "pyvedas_gemm_job(as, bs, cs, 8, 8, 8, 0, 0, 0, 8, 8, 8, scratch_c);",
            text,
        )
        self.assertNotIn("for (size_t m0", text)
        self.assertNotIn("choose_tile", text)

    def test_forced_pe_tiles_are_constants(self) -> None:
        cap = tile_scratch_bytes(8, 8, 32, 32, 32)
        text = emit_gemm_c(
            "pyvedas_gemm_job", "a", "b", "c", (32, 32), (32, 32), cap
        )
        self.assertIn("const size_t mt = 8;", text)
        self.assertIn("const size_t nt = 8;", text)
        self.assertIn("const size_t kt = 32;", text)
        self.assertIn("for (size_t m0 = 0; m0 < 32; m0 += mt)", text)
        self.assertIn(
            "pyvedas_gemm_job(as, bs, cs, 32, 32, 32, m0, n0, k0, mti, nti, kti, scratch_c);",
            text,
        )

    def test_bmm_batch_loop(self) -> None:
        text = emit_gemm_c(
            "pyvedas_gemm_job",
            "a",
            "b",
            "c",
            (4, 8, 8),
            (4, 8, 8),
            128 * 1024,
        )
        self.assertIn("for (size_t b0 = 0; b0 < 4; b0++)", text)
        self.assertIn("const int32_t *as = a + b0 * 64;", text)
        self.assertIn(
            "pyvedas_gemm_job(as, bs, cs, 8, 8, 8, 0, 0, 0, 8, 8, 8, scratch_c);",
            text,
        )

    def test_broadcast_b_is_not_indexed(self) -> None:
        text = emit_gemm_c(
            "pyvedas_gemm_job",
            "a",
            "b",
            "c",
            (3, 1, 8, 8),
            (8, 8),
            128 * 1024,
        )
        self.assertIn("for (size_t b0 = 0; b0 < 3; b0++)", text)
        self.assertIn("for (size_t b1 = 0; b1 < 1; b1++)", text)
        self.assertIn("const int32_t *bs = b;", text)


if __name__ == "__main__":
    unittest.main()
