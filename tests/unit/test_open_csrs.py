# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""open-csrs generator emits vstart/vl/vtype/vlenb."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO / "open-csrs" / "src") not in sys.path:
    sys.path.insert(0, str(_REPO / "open-csrs" / "src"))

import main as open_csrs  # noqa: E402


class TestOpenCsrs(unittest.TestCase):
    def test_generate_vector_csrs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            rc = open_csrs.main(
                [
                    "-t",
                    str(_REPO / "open-csrs" / "tables" / "csrs.yaml"),
                    "-o",
                    str(out),
                ]
            )
            self.assertEqual(rc, 0)
            pkg = (out / "csr_pkg.svh").read_text(encoding="utf-8")
            rtl = (out / "csr_file.sv").read_text(encoding="utf-8")
            self.assertIn("CSR_VSTART_ADDR = 12'h008", pkg)
            self.assertIn("CSR_VL_ADDR = 12'hC20", pkg)
            self.assertIn("CSR_VTYPE_ADDR = 12'hC21", pkg)
            self.assertIn("CSR_VLENB_ADDR = 12'hC22", pkg)
            self.assertIn("vset_we", rtl)
            self.assertIn("VLENB_CONST", rtl)


if __name__ == "__main__":
    unittest.main()
