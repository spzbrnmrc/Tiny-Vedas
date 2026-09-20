# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS vector compares (packed mask dest)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO / "tools") not in sys.path:
    sys.path.insert(0, str(_REPO / "tools"))

from rv_iss import RISC_V_ISS  # noqa: E402


class TestVcmp(unittest.TestCase):
    def test_cmp_bits(self) -> None:
        n3 = (-3) & 0xFFFFFFFF
        n1 = (-1) & 0xFFFFFFFF
        self.assertTrue(RISC_V_ISS._valu_cmp(0x18, 5, 5))
        self.assertFalse(RISC_V_ISS._valu_cmp(0x18, n3, 0))
        self.assertTrue(RISC_V_ISS._valu_cmp(0x19, 5, 0))
        self.assertFalse(RISC_V_ISS._valu_cmp(0x19, 0, 0))
        self.assertTrue(RISC_V_ISS._valu_cmp(0x1B, n3, 0))
        self.assertFalse(RISC_V_ISS._valu_cmp(0x1B, 0, n1))
        self.assertTrue(RISC_V_ISS._valu_cmp(0x1F, 5, 0))
        self.assertFalse(RISC_V_ISS._valu_cmp(0x1F, 0, 0))
        self.assertFalse(RISC_V_ISS._valu_cmp(0x1A, n3, 5))
        self.assertTrue(RISC_V_ISS._valu_cmp(0x1A, 0, 5))
        self.assertTrue(RISC_V_ISS._valu_cmp(0x1D, 5, 5))
        self.assertTrue(RISC_V_ISS._valu_cmp(0x1D, n3, 0))
        self.assertFalse(RISC_V_ISS._valu_cmp(0x1D, 0, n1))


if __name__ == "__main__":
    unittest.main()
