# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Requant calibration file ABI and apply pass."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import torch
import torch.nn as nn

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))
_PYVEDAS = _REPO / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from models.yolov3_tiny.int32 import quantize_int32  # noqa: E402
from models.yolov3_tiny.model import YoloV3Tiny  # noqa: E402
from requant_cal import (  # noqa: E402
    LayerCal,
    RequantCal,
    apply_requant_calibration,
    choose_mul_shift,
    dump_requant_cal,
    load_requant_cal,
)


class _DummyConv(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.requant_mul = 1
        self.requant_shift = 7
        self.weight_scale = torch.tensor([2.0, 4.0])
        self.bias_f = torch.tensor([12.0, 24.0])
        self.register_buffer("bias", torch.tensor([12, 24], dtype=torch.int32))


class _DummyNet(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.c0 = _DummyConv()
        self.c2 = _DummyConv()


class TestChooseMulShift(unittest.TestCase):
    def test_exact_power_of_two(self) -> None:
        self.assertEqual(choose_mul_shift(0.25), (1, 2))

    def test_rejects_non_positive(self) -> None:
        self.assertEqual(choose_mul_shift(0.0), (1, 0))
        self.assertEqual(choose_mul_shift(-1.0), (1, 0))


class TestCalFile(unittest.TestCase):
    def test_roundtrip(self) -> None:
        cal = RequantCal(
            version=1,
            layers={
                "c0": LayerCal(scale_x=0.0078125, requant_mul=17, requant_shift=8),
            },
        )
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "cal.yaml"
            dump_requant_cal(cal, path)
            loaded = load_requant_cal(path)
        self.assertEqual(loaded.version, 1)
        self.assertEqual(loaded.layers["c0"].requant_mul, 17)
        self.assertEqual(loaded.layers["c0"].requant_shift, 8)
        self.assertAlmostEqual(loaded.layers["c0"].scale_x, 0.0078125)

    def test_bad_version(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "cal.yaml"
            path.write_text("version: 99\nlayers: {}\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                load_requant_cal(path)


class TestApply(unittest.TestCase):
    def test_writes_mul_shift_and_bias(self) -> None:
        net = _DummyNet()
        cal = RequantCal(
            version=1,
            layers={
                "c0": LayerCal(scale_x=2.0, requant_mul=17, requant_shift=8),
            },
        )
        apply_requant_calibration(net, cal)
        self.assertEqual(net.c0.requant_mul, 17)
        self.assertEqual(net.c0.requant_shift, 8)
        # bias = round(bias_f / (scale_w * scale_x)) = [12/4, 24/8] = [3, 3]
        self.assertEqual(net.c0.bias.tolist(), [3, 3])
        self.assertEqual(net.c2.requant_mul, 1)
        self.assertEqual(net.c2.requant_shift, 7)
        self.assertEqual(net.c2.bias.tolist(), [12, 24])

    def test_zero_point_adds_weight_sum(self) -> None:
        net = _DummyNet()
        net.c0.weight = torch.ones(2, 1, 1, 1, dtype=torch.int32)
        cal = RequantCal(
            version=1,
            layers={
                "c0": LayerCal(
                    scale_x=2.0, requant_mul=1, requant_shift=0, zero_point=2
                ),
            },
        )
        apply_requant_calibration(net, cal)
        # base [3, 3] + 2 * sum(ones 1x1x1) = [5, 5]
        self.assertEqual(net.c0.bias.tolist(), [5, 5])


class TestQuantizeDefaults(unittest.TestCase):
    def test_no_cal_keeps_first_design(self) -> None:
        model = quantize_int32(YoloV3Tiny())
        self.assertEqual(model.c0.requant_mul, 1)
        self.assertEqual(model.c0.requant_shift, 7)
        self.assertEqual(model.c12.requant_shift, 7)
        self.assertEqual(model.c15.requant_mul, 1)
        self.assertEqual(model.c15.requant_shift, 6)
        self.assertEqual(model.c22.requant_shift, 6)
        self.assertIsNotNone(model.c0.weight_scale)
        self.assertTrue(torch.equal(model.c0.bias, torch.round(model.c0.bias_f).to(torch.int32)))
        self.assertTrue(torch.allclose(model.c0.weight_scale, model.c0.weight_scale[:1]))

    def test_cal_overrides_named_layer(self) -> None:
        cal = RequantCal(
            version=1,
            layers={
                "c0": LayerCal(scale_x=0.5, requant_mul=3, requant_shift=4),
            },
        )
        model = quantize_int32(YoloV3Tiny(), cal=cal)
        self.assertEqual(model.c0.requant_mul, 3)
        self.assertEqual(model.c0.requant_shift, 4)
        self.assertEqual(model.c2.requant_mul, 1)
        self.assertEqual(model.c2.requant_shift, 7)


class TestNoCodegenYoloTable(unittest.TestCase):
    def test_handlers_have_no_yolo_requant_table(self) -> None:
        text = (_PYVEDAS / "jit" / "codegen_handlers.py").read_text(encoding="utf-8")
        self.assertNotIn("backbone_c12", text)
        self.assertNotIn("requant_params", text)
        self.assertIn("node.args[1]", text)


if __name__ == "__main__":
    unittest.main()
