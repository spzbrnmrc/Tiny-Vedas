# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Integer YOLO export unique ops are all in ops.yaml."""

from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path

import torch

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))
_PYVEDAS = _REPO / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from jit.codegen_handlers import choose_pool_stream_tiles  # noqa: E402
from jit.compile import compile_model  # noqa: E402
from jit.memory.gemm_tiles import choose_conv_tiles, conv_oc_tiles  # noqa: E402
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

    def test_stream_compile_tiny(self) -> None:
        model = quantize_int32(YoloV3Tiny()).eval()
        x = torch.randint(-8, 9, (1, 3, 32, 32), dtype=torch.int32)
        with tempfile.TemporaryDirectory() as td:
            generated = compile_model(
                model,
                (x,),
                _PYVEDAS,
                Path(td),
                target=True,
                stream=True,
            )
            self.assertTrue(generated.is_file())
            hex_path = Path(td) / "dram.hex"
            self.assertTrue(hex_path.is_file())
            text = generated.read_text(encoding="utf-8")
            self.assertIn("DRAM_BASE", text)
            self.assertTrue(
                "stream_col" in text or "stream_col_cache" in text
            )
            self.assertIn("pyvedas_im2col_tile", text)
            self.assertIn("_pyvedas_op_limit", text)
            self.assertIn("_pyvedas_eot", text)
            self.assertTrue(
                ("stream_act" in text and "pyvedas_memcpy(stream_act" in text)
                or "for (size_t oc0" in text
            )
            _assert_pack_outside_spatial(self, text)


def _assert_pack_outside_spatial(test: unittest.TestCase, text: str) -> None:
    """STREAM conv emits one of the three documented nests."""
    found = 0
    idx = 0
    while True:
        i = text.find("const size_t oc_t =", idx)
        if i < 0:
            break
        block = text[i : i + 2200]
        found += 1
        i_oc = block.find("for (size_t oc0")
        i_pack = block.find("pack_weight")
        i_oh = block.find("for (size_t oh0")
        i_im = block.find("im2col_tile")
        test.assertGreaterEqual(i_oc, 0, msg=block[:300])
        test.assertGreaterEqual(i_pack, 0, msg=block[:300])
        test.assertGreaterEqual(i_oh, 0, msg=block[:300])
        test.assertGreaterEqual(i_im, 0, msg=block[:300])
        spatial_outer = i_oh < i_im < i_oc < i_pack
        oc_outer = i_oc < i_pack < i_oh < i_im
        cache_col = i_im < i_oc < i_pack
        test.assertTrue(
            spatial_outer or oc_outer or cache_col,
            msg=f"nest {i_oc} {i_pack} {i_oh} {i_im}\n{block[:600]}",
        )
        idx = i + 1
    test.assertGreater(found, 0)


class TestC12StreamPackHoist(unittest.TestCase):
    def test_c12_shaped_conv_is_oc_outer(self) -> None:
        from conv_op import conv2d
        import torch.nn as nn

        class C12(nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.register_buffer(
                    "weight",
                    torch.randint(-2, 3, (256, 128, 3, 3), dtype=torch.int32),
                )
                self.register_buffer(
                    "bias", torch.zeros(256, dtype=torch.int32)
                )

            def forward(self, x: torch.Tensor) -> torch.Tensor:
                return conv2d(x, self.weight, self.bias, 1, 1)

        x = torch.randint(-8, 9, (1, 128, 6, 6), dtype=torch.int32)
        with tempfile.TemporaryDirectory() as td:
            generated = compile_model(
                C12().eval(),
                (x,),
                _PYVEDAS,
                Path(td),
                target=True,
                stream=True,
                goldens=False,
            )
            text = generated.read_text(encoding="utf-8")
        oh_t, ow_t, oc_t = choose_conv_tiles(1, 128, 256, 3, 3, 6, 6)
        spatial = ((6 + oh_t - 1) // oh_t) * ((6 + ow_t - 1) // ow_t)
        packs = conv_oc_tiles(256, oc_t)
        self.assertGreater(spatial, 1)
        self.assertGreater(spatial * packs, packs)
        _assert_pack_outside_spatial(self, text)
        self.assertIn("for (size_t oh0", text)
        self.assertIn("pack_weight", text)
        self.assertIn("stream_col_cache", text)
        self.assertNotIn("static int32_t stream_act[", text)


class TestPoolStreamTiles(unittest.TestCase):
    def test_tiny_c0_pool_fits_slab(self) -> None:
        tiles = choose_pool_stream_tiles(16, 208, 208, 104, 104, 2, 2, 2, 2)
        self.assertIsNotNone(tiles)
        c_t, oh_t, ow_t = tiles
        h_span = (oh_t - 1) * 2 + 2
        w_span = (ow_t - 1) * 2 + 2
        self.assertLessEqual(w_span, 64)
        self.assertLessEqual(c_t * h_span * w_span, 32768)
        self.assertLessEqual(c_t * oh_t * ow_t, 32768)

    def test_rejects_kernel_wider_than_rvv_row(self) -> None:
        self.assertIsNone(
            choose_pool_stream_tiles(1, 8, 8, 1, 1, 1, 128, 1, 1)
        )


if __name__ == "__main__":
    unittest.main()
