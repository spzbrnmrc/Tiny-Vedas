# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for the GEMM fit-or-tile planner (Python + C lockstep)."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
_PYVEDAS = _REPO / "pyvedas"
if str(_PYVEDAS) not in sys.path:
    sys.path.insert(0, str(_PYVEDAS))

from jit.memory.gemm_tiles import (  # noqa: E402
    SCRATCH_CAP_BYTES,
    choose_tile,
    live_bytes_2d,
    matmul_out_shape,
    plan_gemm_jobs,
    scratch_budget,
    tile_scratch_bytes,
)


class TestScratchBudget(unittest.TestCase):
    def test_one_shot_fits_default_scratch(self) -> None:
        for m, n, k in ((8, 8, 8), (32, 32, 32), (128, 128, 128)):
            budget = scratch_budget(live_bytes_2d(m, n, k))
            self.assertGreaterEqual(budget, tile_scratch_bytes(m, n, k, n, k))
            jobs = plan_gemm_jobs(m, n, k, budget)
            self.assertEqual(len(jobs), 1)
            self.assertEqual(
                (jobs[0].m0, jobs[0].n0, jobs[0].k0, jobs[0].m_t, jobs[0].n_t, jobs[0].k_t),
                (0, 0, 0, m, n, k),
            )

    def test_256_square_is_one_shot_at_cap(self) -> None:
        jobs = plan_gemm_jobs(256, 256, 8, SCRATCH_CAP_BYTES)
        self.assertEqual(len(jobs), 1)

    def test_exceeds_old_256_sq_pack_splits_k(self) -> None:
        # 512*257 > 256**2, so the old whole-matrix pack hung.
        m, n, k = 512, 8, 257
        budget = scratch_budget(live_bytes_2d(m, n, k))
        self.assertLess(budget, tile_scratch_bytes(m, n, k, n, k))
        jobs = plan_gemm_jobs(m, n, k, budget)
        self.assertGreater(len(jobs), 1)
        self.assertEqual(sum(j.k_t for j in jobs if j.m0 == 0 and j.n0 == 0), k)
        tile = choose_tile(m, n, k, budget)
        assert tile is not None
        m_t, n_t, k_t = tile
        if m_t < m:
            self.assertEqual(m_t % 8, 0)
        if n_t < n:
            self.assertEqual(n_t % 8, 0)
        if k_t < k:
            self.assertEqual(k_t % 32, 0)


class TestForcedSmallBudget(unittest.TestCase):
    def test_32_cube_with_pe_scratch(self) -> None:
        budget = tile_scratch_bytes(8, 8, 32, 32, 32)
        jobs = plan_gemm_jobs(32, 32, 32, budget)
        self.assertGreater(len(jobs), 1)
        tile = choose_tile(32, 32, 32, budget)
        self.assertEqual(tile, (8, 8, 32))
        self.assertEqual(len(jobs), 4 * 4 * 1)

    def test_remainder_smaller_than_pe(self) -> None:
        # 8x8x32 full-width one-K pack is 512 B; 9x8x32 needs 544 B.
        jobs = plan_gemm_jobs(9, 8, 32, 512)
        self.assertGreaterEqual(len(jobs), 2)
        last_m = max(j.m0 + j.m_t for j in jobs)
        self.assertEqual(last_m, 9)
        small = [j for j in jobs if j.m_t < 8]
        self.assertTrue(all(j.m_t == 1 for j in small))

    def test_no_fit_returns_empty(self) -> None:
        self.assertEqual(plan_gemm_jobs(8, 8, 32, 16), [])
        self.assertIsNone(choose_tile(8, 8, 32, 16))


class TestMatmulShapes(unittest.TestCase):
    def test_rank2(self) -> None:
        self.assertEqual(matmul_out_shape((8, 4), (4, 16)), (8, 16))

    def test_bmm(self) -> None:
        self.assertEqual(matmul_out_shape((4, 8, 8), (4, 8, 8)), (4, 8, 8))

    def test_broadcast(self) -> None:
        self.assertEqual(matmul_out_shape((3, 1, 8, 8), (8, 8)), (3, 1, 8, 8))

    def test_inner_mismatch(self) -> None:
        with self.assertRaises(ValueError):
            matmul_out_shape((8, 4), (5, 8))


def _compile_host() -> Path:
    work = _REPO / "work" / "unit"
    work.mkdir(parents=True, exist_ok=True)
    bin_path = work / "gemm_tile_host"
    srcs = [
        _PYVEDAS / "runtime" / "c" / "gemm_tile.c",
        _REPO / "tests" / "unit" / "gemm_tile_host.c",
    ]
    cmd = [
        "gcc",
        "-std=c11",
        "-O0",
        "-I",
        str(_PYVEDAS / "runtime" / "include"),
        "-o",
        str(bin_path),
        *[str(p) for p in srcs],
    ]
    subprocess.run(cmd, check=True)
    return bin_path


class TestCLockstep(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bin = _compile_host()

    def _parse(self, m: int, n: int, k: int, budget: int):
        out = subprocess.check_output(
            [str(self.bin), str(m), str(n), str(k), str(budget)],
            text=True,
        )
        lines = out.splitlines()
        if lines[0] == "none":
            return None, []
        _, mt, nt, kt = lines[0].split()
        jobs = []
        for line in lines[2:]:
            jobs.append(tuple(int(x) for x in line.split()))
        return (int(mt), int(nt), int(kt)), jobs

    def test_matches_python(self) -> None:
        cases = [
            (8, 8, 8, 131072),
            (32, 32, 32, 131072),
            (128, 128, 128, 131072),
            (512, 8, 257, scratch_budget(live_bytes_2d(512, 8, 257))),
            (32, 32, 32, tile_scratch_bytes(8, 8, 32, 32, 32)),
            (9, 8, 32, 512),
            (5, 3, 4, 131072),
        ]
        for m, n, k, budget in cases:
            with self.subTest(m=m, n=n, k=k, budget=budget):
                c_tile, c_jobs = self._parse(m, n, k, budget)
                py_tile = choose_tile(m, n, k, budget)
                py_jobs = [
                    (j.m0, j.n0, j.k0, j.m_t, j.n_t, j.k_t)
                    for j in plan_gemm_jobs(m, n, k, budget)
                ]
                self.assertEqual(c_tile, py_tile)
                self.assertEqual(c_jobs, py_jobs)


if __name__ == "__main__":
    unittest.main()
