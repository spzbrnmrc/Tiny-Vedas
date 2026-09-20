# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Hardware presets and predicated smoke tlists."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from hw import load_hw_config  # noqa: E402
from hw.rtl_config import render_hw_config_svh  # noqa: E402
from tools.sim_manager import read_task_list  # noqa: E402


class TestHwPresets(unittest.TestCase):
    def test_scalar_default_has_no_vector(self) -> None:
        cfg = load_hw_config(_REPO / "hw" / "presets" / "rv32im_scalar.yaml")
        self.assertFalse(cfg.has_vector_unit)
        self.assertEqual(cfg.vector.dlen_bits, 0)

    def test_fpga_gen_config_vector_on(self) -> None:
        import subprocess

        with tempfile.TemporaryDirectory() as td:
            subprocess.check_call(
                [
                    sys.executable,
                    str(_REPO / "fpga" / "alveo_u280" / "scripts" / "gen_fpga_config.py"),
                    "--board-dir",
                    str(_REPO / "fpga" / "alveo_u280"),
                    "--work-dir",
                    td,
                ]
            )
            svh = Path(td, "include", "hw_config.svh").read_text(encoding="utf-8")
        self.assertIn("localparam bit HAS_VECTOR = 1;", svh)
        self.assertIn("localparam int VLEN = 512;", svh)
        self.assertIn("localparam int DLEN = 128;", svh)

    def test_zve32x_preset(self) -> None:
        cfg = load_hw_config(_REPO / "hw" / "presets" / "rv32im_zve32x.yaml")
        self.assertTrue(cfg.has_vector_unit)
        self.assertEqual(cfg.vector.width_bits, 512)
        self.assertEqual(cfg.vector.dlen_bits, 128)
        self.assertEqual(cfg.vector.lanes, 16)
        svh = render_hw_config_svh(cfg)
        self.assertIn("localparam bit HAS_VECTOR = 1;", svh)
        self.assertIn("localparam int VLEN = 512;", svh)
        self.assertIn("localparam int DLEN = 128;", svh)


class TestTlistPredicates(unittest.TestCase):
    def _write(self, body: str) -> Path:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".tlist", delete=False)
        tmp.write(body)
        tmp.close()
        return Path(tmp.name)

    def test_skip_vector_on_scalar(self) -> None:
        path = self._write(
            "asm.basic_lui\n"
            "asm.rvv_vset if vector.enabled\n"
            "# comment\n"
        )
        cfg = load_hw_config(_REPO / "hw" / "presets" / "rv32im_scalar.yaml")
        self.assertEqual(read_task_list(str(path), cfg), ["asm.basic_lui"])

    def test_include_vector_on_zve32x(self) -> None:
        path = self._write(
            "asm.basic_lui\n"
            "asm.rvv_vset if vector.enabled\n"
        )
        cfg = load_hw_config(_REPO / "hw" / "presets" / "rv32im_zve32x.yaml")
        self.assertEqual(
            read_task_list(str(path), cfg),
            ["asm.basic_lui", "asm.rvv_vset"],
        )


if __name__ == "__main__":
    unittest.main()
