# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""YOLOv3-Tiny: exportable graph at 208 and 416; required ops present."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import torch

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from models.yolov3_tiny.export_graph import (  # noqa: E402
    call_functions,
    export_module,
    required_ops_present,
)
from models.yolov3_tiny.model import (  # noqa: E402
    NUM_CONV_WEIGHTS,
    YoloV3Tiny,
    quantize_int8,
)
from models.yolov3_tiny.post import map50  # noqa: E402
from models.yolov3_tiny.weights import (  # noqa: E402
    conv_weight_count,
    default_weights_path,
    load_darknet_weights,
)


class TestYoloV3TinyGraph(unittest.TestCase):
    def test_conv_weight_count(self) -> None:
        model = YoloV3Tiny()
        self.assertEqual(conv_weight_count(model), NUM_CONV_WEIGHTS)

    def test_forward_shapes_416(self) -> None:
        model = YoloV3Tiny().eval()
        d32, d16 = model(torch.zeros(1, 3, 416, 416))
        self.assertEqual(tuple(d32.shape), (1, 255, 13, 13))
        self.assertEqual(tuple(d16.shape), (1, 255, 26, 26))

    def test_forward_shapes_208(self) -> None:
        model = YoloV3Tiny().eval()
        d32, d16 = model(torch.zeros(1, 3, 208, 208))
        # 208/32 floors to 6; skip is 13; concat is aligned to the skip.
        self.assertEqual(tuple(d32.shape), (1, 255, 6, 6))
        self.assertEqual(tuple(d16.shape), (1, 255, 13, 13))

    def test_export_int8_required_ops(self) -> None:
        model = quantize_int8(YoloV3Tiny()).eval()
        for size in (208, 416):
            gm, backend = export_module(model, (torch.randn(1, 3, size, size),))
            self.assertEqual(backend, "torch.export")
            unique = sorted(set(call_functions(gm.graph)))
            present = required_ops_present(unique)
            self.assertTrue(present["conv2d"], unique)
            self.assertTrue(present["leaky_relu"], unique)
            self.assertTrue(present["max_pool"], unique)

    def test_map50_perfect_is_one(self) -> None:
        box = torch.tensor([[10.0, 10.0, 50.0, 50.0, 0.9, 0.0]])
        tgt = torch.tensor([[0.0, 10.0, 10.0, 50.0, 50.0]])
        self.assertGreater(map50([box], [tgt], num_classes=1), 0.0)
        self.assertAlmostEqual(map50([box], [tgt], num_classes=1), 1.0)

    def test_load_official_weights_if_cached(self) -> None:
        path = default_weights_path()
        if not path.is_file():
            self.skipTest(f"no cached weights at {path}")
        model = YoloV3Tiny()
        load_darknet_weights(model, path)
        d32, _ = model.eval()(torch.zeros(1, 3, 416, 416))
        self.assertEqual(tuple(d32.shape), (1, 255, 13, 13))


if __name__ == "__main__":
    unittest.main()
