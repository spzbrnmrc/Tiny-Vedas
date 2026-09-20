# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""ISS unit-stride vle32.v / vse32.v (shared with rtl/vector/vector_top.sv)."""

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


class TestVmem(unittest.TestCase):
    def test_vle32_vse32_roundtrip(self) -> None:
        cpu = _iss()
        cpu._apply_vset(1, 16, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        for i in range(16):
            cpu.mem.write_word(4 * i, (i + 1) * 0x11111111)
        cpu._exec_vle32(1, 0)
        self.assertEqual(cpu.vregs[1][0], 0x11111111)
        self.assertEqual(cpu.vregs[1][15], 0x11111111 * 16 & 0xFFFFFFFF)
        cpu.regs.write(11, 0x80)
        cpu._exec_vse32(1, 11)
        self.assertEqual(cpu.mem.read_word(0x80), 0x11111111)
        self.assertEqual(cpu.mem.read_word(0x80 + 60), 0x11111111 * 16 & 0xFFFFFFFF)

    def test_vle32_tail_agnostic(self) -> None:
        cpu = _iss()
        cpu._apply_vset(1, 3, RISC_V_ISS.VTYPE_LEGAL, keep_vl=False)
        for i in range(4):
            cpu.mem.write_word(4 * i, i + 1)
        cpu._exec_vle32(2, 0)
        self.assertEqual(cpu.vregs[2][0], 1)
        self.assertEqual(cpu.vregs[2][2], 3)
        self.assertEqual(cpu.vregs[2][3], 0xFFFFFFFF)
        self.assertEqual(cpu.vregs[2][15], 0xFFFFFFFF)

    def test_vse32_vl0_is_nop(self) -> None:
        cpu = _iss()
        cpu.vregs[1][0] = 0xDEADBEEF
        cpu.regs.write(11, 0x40)
        cpu.mem.write_word(0x40, 0xA5A5A5A5)
        cpu._exec_vse32(1, 11)
        self.assertEqual(cpu.mem.read_word(0x40), 0xA5A5A5A5)


if __name__ == "__main__":
    unittest.main()
