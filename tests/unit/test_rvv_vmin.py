# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS vmin/vmax (shared with rtl/vector/vector_top.sv)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO / "tools") not in sys.path:
    sys.path.insert(0, str(_REPO / "tools"))

from rv_iss import RISC_V_ISS  # noqa: E402


class TestVmin(unittest.TestCase):
    def test_signed_unsigned(self) -> None:
        imin = 0x80000000
        imax = 0x7FFFFFFF
        self.assertEqual(RISC_V_ISS._valu_op(0x05, 5, 3), 3)
        self.assertEqual(RISC_V_ISS._valu_op(0x05, (-3) & 0xFFFFFFFF, (-8) & 0xFFFFFFFF),
                         (-8) & 0xFFFFFFFF)
        self.assertEqual(RISC_V_ISS._valu_op(0x05, imin, 0), imin)
        self.assertEqual(RISC_V_ISS._valu_op(0x07, imax, (-1) & 0xFFFFFFFF), imax)
        self.assertEqual(RISC_V_ISS._valu_op(0x04, imin, 0), 0)
        self.assertEqual(RISC_V_ISS._valu_op(0x06, imin, 0), imin)
        self.assertEqual(RISC_V_ISS._valu_op(0x06, imax, (-1) & 0xFFFFFFFF),
                         (-1) & 0xFFFFFFFF)
        self.assertEqual(RISC_V_ISS._valu_op(0x07, (-3) & 0xFFFFFFFF, 0), 0)


if __name__ == "__main__":
    unittest.main()
