# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Graph op → C statement handlers.

Each handler reads/writes a :class:`MemoryPlan` and returns one statement
(possibly a brace block). Register new handlers in ``CODEGEN_HANDLERS``
keyed by ``RuntimeOp.codegen``.
"""

from __future__ import annotations

from typing import List, Sequence

import torch.fx as fx

from .memory import (
    BufferLayout,
    ElementType,
    MemoryPlan,
    StaticBuffer,
    format_shape,
)
from .memory.gemm_tiles import (
    SCRATCH_CAP_BYTES,
    choose_tile,
    matmul_out_shape,
    numel,
    scratch_budget,
    tile_scratch_bytes,
)
from .registry import RegistryError, RuntimeOp


def _buffer_name(node: fx.Node) -> str:
    return node.name.replace("%", "v_")


def emit_elementwise_binary(
    op: RuntimeOp,
    node: fx.Node,
    memory: MemoryPlan,
    **_kwargs,
) -> str:
    if len(node.args) != 2:
        raise RegistryError(
            f"{op.graph_target} expects two operands (node {node.name})"
        )

    lhs = _buffer_name(node.args[0])
    rhs = _buffer_name(node.args[1])
    out = _buffer_name(node)

    try:
        lhs_buf = memory.get(lhs)
        rhs_buf = memory.get(rhs)
    except KeyError as exc:
        raise RegistryError(
            f"Missing buffer for {op.graph_target} (node {node.name})"
        ) from exc

    if lhs_buf.numel != rhs_buf.numel:
        raise RegistryError(f"{op.graph_target} requires equal numel operands")
    if lhs_buf.shape != rhs_buf.shape:
        raise RegistryError(
            f"{op.graph_target} requires matching shapes "
            f"({format_shape(lhs_buf.shape)} vs {format_shape(rhs_buf.shape)})"
        )

    memory.allocate_uninitialized(out, lhs_buf)
    return f"{op.symbol}({lhs}, {rhs}, {out}, {lhs_buf.numel});"


def _batch_offset_expr(
    coord_names: Sequence[str],
    orig_batch: Sequence[int],
    out_batch: Sequence[int],
    inner: int,
) -> str:
    rank = len(out_batch)
    orig = (1,) * (rank - len(orig_batch)) + tuple(orig_batch)
    terms: List[str] = []
    stride = inner
    for i in range(rank - 1, -1, -1):
        if orig[i] != 1:
            terms.append(f"{coord_names[i]} * {stride}")
        stride *= orig[i]
    if not terms:
        return "0"
    return " + ".join(reversed(terms))


def emit_gemm_c(
    symbol: str,
    lhs: str,
    rhs: str,
    out: str,
    a_shape: Sequence[int],
    b_shape: Sequence[int],
    scratch_cap: int,
) -> str:
    """Emit a compiler-planned GEMM: tile sizes are constants, runtime runs jobs."""
    a_shape = tuple(int(d) for d in a_shape)
    b_shape = tuple(int(d) for d in b_shape)
    try:
        out_shape = matmul_out_shape(a_shape, b_shape)
    except ValueError as exc:
        raise RegistryError(f"gemm_mmio: {exc}") from exc

    m, k = a_shape[-2], a_shape[-1]
    n = b_shape[-1]
    out_batch = out_shape[:-2]
    a_batch = a_shape[:-2]
    b_batch = b_shape[:-2]
    live = 4 * (numel(a_shape) + numel(b_shape) + numel(out_shape))
    budget = scratch_budget(live, scratch_cap=scratch_cap)
    tile = choose_tile(m, n, k, budget)
    if tile is None:
        raise RegistryError(
            f"gemm_mmio: no tile of {m}x{n}x{k} fits scratch budget {budget}"
        )
    mt, nt, kt = tile
    scratch_bytes = tile_scratch_bytes(mt, nt, kt, n, k)
    scratch = f"scratch_{out}"
    coords = [f"b{i}" for i in range(len(out_batch))]
    a_off = _batch_offset_expr(coords, a_batch, out_batch, m * k)
    b_off = _batch_offset_expr(coords, b_batch, out_batch, k * n)
    c_off = _batch_offset_expr(coords, out_batch, out_batch, m * n)

    lines: List[str] = ["{"]
    lines.append(
        f"    static uint8_t {scratch}[{scratch_bytes}] "
        "__attribute__((aligned(4)));"
    )
    lines.append(f"    const size_t mt = {mt};")
    lines.append(f"    const size_t nt = {nt};")
    lines.append(f"    const size_t kt = {kt};")

    indent = 1

    def add(s: str) -> None:
        lines.append(("    " * indent) + s)

    for i, dim in enumerate(out_batch):
        add(f"for (size_t b{i} = 0; b{i} < {int(dim)}; b{i}++) {{")
        indent += 1

    if a_off == "0":
        add(f"const int32_t *as = {lhs};")
    else:
        add(f"const int32_t *as = {lhs} + {a_off};")
    if b_off == "0":
        add(f"const int32_t *bs = {rhs};")
    else:
        add(f"const int32_t *bs = {rhs} + {b_off};")
    if c_off == "0":
        add(f"int32_t *cs = {out};")
    else:
        add(f"int32_t *cs = {out} + {c_off};")

    one_shot = mt == m and nt == n and kt == k
    if one_shot:
        add(
            f"{symbol}(as, bs, cs, {m}, {n}, {k}, "
            f"0, 0, 0, {m}, {n}, {k}, {scratch});"
        )
    else:
        add(f"for (size_t m0 = 0; m0 < {m}; m0 += mt) {{")
        indent += 1
        add(f"size_t mti = {m} - m0;")
        add("if (mti > mt) {")
        add("    mti = mt;")
        add("}")
        add(f"for (size_t n0 = 0; n0 < {n}; n0 += nt) {{")
        indent += 1
        add(f"size_t nti = {n} - n0;")
        add("if (nti > nt) {")
        add("    nti = nt;")
        add("}")
        add(f"for (size_t k0 = 0; k0 < {k}; k0 += kt) {{")
        indent += 1
        add(f"size_t kti = {k} - k0;")
        add("if (kti > kt) {")
        add("    kti = kt;")
        add("}")
        add(
            f"{symbol}(as, bs, cs, {m}, {n}, {k}, "
            f"m0, n0, k0, mti, nti, kti, {scratch});"
        )
        indent -= 1
        add("}")
        indent -= 1
        add("}")
        indent -= 1
        add("}")

    for _ in out_batch:
        indent -= 1
        add("}")

    lines.append("}")
    return "\n".join(lines)


def emit_gemm_mmio(
    op: RuntimeOp,
    node: fx.Node,
    memory: MemoryPlan,
    gemm_scratch_bytes: int | None = None,
    **_kwargs,
) -> str:
    if len(node.args) != 2:
        raise RegistryError(
            f"{op.graph_target} expects A, B (node {node.name})"
        )

    lhs = _buffer_name(node.args[0])
    rhs = _buffer_name(node.args[1])
    out = _buffer_name(node)

    try:
        lhs_buf = memory.get(lhs)
        rhs_buf = memory.get(rhs)
    except KeyError as exc:
        raise RegistryError(
            f"Missing buffer for {op.graph_target} (node {node.name})"
        ) from exc

    if len(lhs_buf.shape) < 2 or len(rhs_buf.shape) < 2:
        raise RegistryError(f"{op.graph_target} requires rank >= 2 A and B")

    try:
        out_shape = matmul_out_shape(lhs_buf.shape, rhs_buf.shape)
    except ValueError as exc:
        raise RegistryError(f"{op.graph_target}: {exc}") from exc

    memory.add(
        StaticBuffer(
            name=out,
            shape=out_shape,
            element=ElementType(c_type="int32_t", size_bytes=4),
            layout=BufferLayout.flat_row_major(numel(out_shape)),
        )
    )

    cap = SCRATCH_CAP_BYTES if gemm_scratch_bytes is None else int(gemm_scratch_bytes)
    return emit_gemm_c(
        op.symbol,
        lhs,
        rhs,
        out,
        lhs_buf.shape,
        rhs_buf.shape,
        cap,
    )


CODEGEN_HANDLERS = {
    "elementwise_binary": emit_elementwise_binary,
    "gemm_mmio": emit_gemm_mmio,
}
