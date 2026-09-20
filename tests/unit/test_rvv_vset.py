# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS vsetvl table (shared with rtl/vector/vector_top.sv)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO / "tools") not in sys.path:
    sys.path.insert(0, str(_REPO / "tools"))

from rv_iss import RISC_V_ISS  # noqa: E402


def _iss() -> RISC_V_ISS:
    cpu = RISC_V_ISS(0x100000, 0x7FFFF000, 0x1000, vlen=512)
    return cpu


class TestVset(unittest.TestCase):
    def test_vlenb_and_reset(self) -> None:
        cpu = _iss()
        self.assertEqual(cpu.vlenb, 64)
        self.assertEqual(cpu.vlmax, 16)
        self.assertEqual(cpu.vl, 0)
        self.assertEqual(cpu.vtype, RISC_V_ISS.VTYPE_VILL)

    def test_avl_clamp_and_vlmax(self) -> None:
        cpu = _iss()
        cpu.regs.write(2, 15)
        cpu._apply_vset(1, cpu.regs.read(2), RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        self.assertEqual(cpu.vl, 15)
        self.assertEqual(cpu.regs.read(1), 15)
        cpu._apply_vset(1, 255, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        self.assertEqual(cpu.vl, 16)
        cpu._apply_vset(1, 16, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        cpu._apply_vset(0, 0, RISC_V_ISS.VTYPE_LEGAL, keep_vl=True)
        self.assertEqual(cpu.vl, 16)

    def test_illegal_vtype(self) -> None:
        cpu = _iss()
        cpu.regs.write(2, 16)
        cpu._apply_vset(1, 16, 0xC8, keep_vl=False)  # e16,m1,ta,ma — not v1 legal
        self.assertEqual(cpu.vl, 0)
        self.assertEqual(cpu.vtype, RISC_V_ISS.VTYPE_VILL)
        self.assertEqual(cpu.regs.read(1), 0)


if __name__ == "__main__":
    unittest.main()
