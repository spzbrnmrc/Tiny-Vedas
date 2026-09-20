# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS vsll/vsrl/vsra (shared with rtl/vector/valu_lane.sv)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO / "tools") not in sys.path:
    sys.path.insert(0, str(_REPO / "tools"))

from rv_iss import RISC_V_ISS  # noqa: E402


class TestVshift(unittest.TestCase):
    def test_shifts(self) -> None:
        imin = 0x80000000
        n8 = (-8) & 0xFFFFFFFF
        self.assertEqual(RISC_V_ISS._valu_op(0x25, 8, 1), 16)
        self.assertEqual(RISC_V_ISS._valu_op(0x25, n8, 2), (-32) & 0xFFFFFFFF)
        self.assertEqual(RISC_V_ISS._valu_op(0x25, imin, 3), 0)
        self.assertEqual(RISC_V_ISS._valu_op(0x25, 15, 4), 240)
        self.assertEqual(RISC_V_ISS._valu_op(0x28, 8, 1), 4)
        self.assertEqual(RISC_V_ISS._valu_op(0x28, n8, 1), 0x7FFFFFFC)
        self.assertEqual(RISC_V_ISS._valu_op(0x28, imin, 1), 0x40000000)
        self.assertEqual(RISC_V_ISS._valu_op(0x29, 8, 1), 4)
        self.assertEqual(RISC_V_ISS._valu_op(0x29, n8, 1), (-4) & 0xFFFFFFFF)
        self.assertEqual(RISC_V_ISS._valu_op(0x29, imin, 1), 0xC0000000)
        self.assertEqual(RISC_V_ISS._valu_op(0x29, imin, 3), 0xF0000000)
        self.assertEqual(RISC_V_ISS._valu_op(0x29, 15, 4), 0)


if __name__ == "__main__":
    unittest.main()
