# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Integer YOLO export unique ops are all in ops.yaml."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import torch

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))
_PYVEDAS = _REPO / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from jit.registry import load_registry, validate_graph_ops  # noqa: E402
from models.yolov3_tiny.export_graph import export_module  # noqa: E402
from models.yolov3_tiny.int32 import (  # noqa: E402
    DecodeHeadsInt32,
    LetterboxInt32,
    quantize_int32,
)
from models.yolov3_tiny.model import YoloV3Tiny  # noqa: E402


class TestIntegerGraphRegistry(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = load_registry(_PYVEDAS)

    def test_backbone_int32(self) -> None:
        model = quantize_int32(YoloV3Tiny()).eval()
        x = torch.randint(-8, 9, (1, 3, 32, 32), dtype=torch.int32)
        gm, backend = export_module(model, (x,))
        self.assertEqual(backend, "torch.export")
        validate_graph_ops(gm.graph, self.registry)

    def test_decode_int32(self) -> None:
        decode = DecodeHeadsInt32(32)
        gm, backend = export_module(
            decode,
            (
                torch.randint(-8, 9, (1, 255, 1, 1), dtype=torch.int32),
                torch.randint(-8, 9, (1, 255, 2, 2), dtype=torch.int32),
            ),
        )
        self.assertEqual(backend, "torch.export")
        validate_graph_ops(gm.graph, self.registry)

    def test_letterbox_int32(self) -> None:
        lb = LetterboxInt32(16)
        gm, backend = export_module(
            lb, (torch.randint(0, 255, (1, 3, 12, 16), dtype=torch.int32),)
        )
        self.assertEqual(backend, "torch.export")
        validate_graph_ops(gm.graph, self.registry)


if __name__ == "__main__":
    unittest.main()
