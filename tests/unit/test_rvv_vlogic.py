# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS vsub / vand / vor / vxor (shared with rtl/vector/vector_top.sv)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO / "tools") not in sys.path:
    sys.path.insert(0, str(_REPO / "tools"))

from rv_iss import RISC_V_ISS  # noqa: E402


def _iss() -> RISC_V_ISS:
    return RISC_V_ISS(0x100000, 0x7FFFF000, 0x1000, vlen=512)


class TestVlogic(unittest.TestCase):
    def test_ops(self) -> None:
        self.assertEqual(RISC_V_ISS._valu_op(0x02, 4, 2), 2)
        self.assertEqual(RISC_V_ISS._valu_op(0x02, 0, 1), 0xFFFFFFFF)
        self.assertEqual(RISC_V_ISS._valu_op(0x03, 4, 5), 1)
        self.assertEqual(RISC_V_ISS._valu_op(0x09, 0x3C, 0x0F), 0x0C)
        self.assertEqual(RISC_V_ISS._valu_op(0x0A, 4, 2), 6)
        self.assertEqual(RISC_V_ISS._valu_op(0x0B, 4, 2), 6)

    def test_vsub_vv(self) -> None:
        cpu = _iss()
        cpu._apply_vset(1, 16, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        for i in range(16):
            cpu.vregs[1][i] = 4 * i
            cpu.vregs[2][i] = i + 1
        inst = (0x02 << 26) | (1 << 25) | (1 << 20) | (2 << 15) | (0 << 12) | (3 << 7) | 0x57
        cpu._exec_valu(inst, 3, 2, 1, 0)
        self.assertEqual(cpu.vregs[3][0], 0xFFFFFFFF)
        self.assertEqual(cpu.vregs[3][1], 2)
        self.assertEqual(cpu.vregs[3][15], 44)


if __name__ == "__main__":
    unittest.main()
