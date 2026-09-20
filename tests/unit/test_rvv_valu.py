# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS vmv / vadd (shared with rtl/vector/vector_top.sv)."""

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


def _load(cpu: RISC_V_ISS, vd: int, vals: list[int]) -> None:
    for i, v in enumerate(vals):
        cpu.vregs[vd][i] = v & 0xFFFFFFFF


class TestValu(unittest.TestCase):
    def test_vadd_vv_vx_vi(self) -> None:
        cpu = _iss()
        cpu._apply_vset(1, 16, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        _load(cpu, 1, [4 * i for i in range(16)])
        _load(cpu, 2, [i + 1 for i in range(16)])
        # vadd.vv v3, v1, v2  funct3=0 funct6=0 vm=1
        inst = (0x00 << 26) | (1 << 25) | (1 << 20) | (2 << 15) | (0 << 12) | (3 << 7) | 0x57
        cpu._exec_valu(inst, 3, 2, 1, 0)
        self.assertEqual(cpu.vregs[3][0], 1)
        self.assertEqual(cpu.vregs[3][1], 6)
        self.assertEqual(cpu.vregs[3][15], 76)
        cpu.regs.write(12, 3)
        inst = (0x00 << 26) | (1 << 25) | (1 << 20) | (12 << 15) | (4 << 12) | (4 << 7) | 0x57
        cpu._exec_valu(inst, 4, 12, 1, 4)
        self.assertEqual(cpu.vregs[4][0], 3)
        self.assertEqual(cpu.vregs[4][15], 63)
        inst = (0x00 << 26) | (1 << 25) | (1 << 20) | (5 << 15) | (3 << 12) | (5 << 7) | 0x57
        cpu._exec_valu(inst, 5, 5, 1, 3)
        self.assertEqual(cpu.vregs[5][0], 5)
        self.assertEqual(cpu.vregs[5][15], 65)

    def test_vmv_and_tail(self) -> None:
        cpu = _iss()
        cpu._apply_vset(1, 4, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        _load(cpu, 1, [10, 20, 30, 40] + [0] * 12)
        inst = (0x17 << 26) | (1 << 25) | (0 << 20) | (1 << 15) | (0 << 12) | (8 << 7) | 0x57
        cpu._exec_valu(inst, 8, 1, 0, 0)
        self.assertEqual(cpu.vregs[8][0], 10)
        self.assertEqual(cpu.vregs[8][3], 40)
        self.assertEqual(cpu.vregs[8][4], 0xFFFFFFFF)
        cpu.regs.write(13, 0xA5A5A5A5)
        inst = (0x17 << 26) | (1 << 25) | (0 << 20) | (13 << 15) | (4 << 12) | (6 << 7) | 0x57
        cpu._exec_valu(inst, 6, 13, 0, 4)
        self.assertEqual(cpu.vregs[6][0], 0xA5A5A5A5)
        self.assertEqual(cpu.vregs[6][15], 0xFFFFFFFF)
        inst = (0x17 << 26) | (1 << 25) | (0 << 20) | (0x1F << 15) | (3 << 12) | (7 << 7) | 0x57
        cpu._exec_valu(inst, 7, 0x1F, 0, 3)
        self.assertEqual(cpu.vregs[7][0], 0xFFFFFFFF)
        self.assertEqual(cpu.vregs[7][3], 0xFFFFFFFF)

    def test_vill_nop(self) -> None:
        cpu = _iss()
        cpu.vregs[3][0] = 0x11111111
        inst = (0x00 << 26) | (1 << 25) | (1 << 20) | (2 << 15) | (0 << 12) | (3 << 7) | 0x57
        cpu._exec_valu(inst, 3, 2, 1, 0)
        self.assertEqual(cpu.vregs[3][0], 0x11111111)

    def test_sext5(self) -> None:
        self.assertEqual(RISC_V_ISS._sext5(5), 5)
        self.assertEqual(RISC_V_ISS._sext5(0x1F) & 0xFFFFFFFF, 0xFFFFFFFF)


if __name__ == "__main__":
    unittest.main()
