# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Graph op → C statement handlers.

Each handler reads/writes a :class:`LoweringCtx` and returns one statement
(possibly a brace block). Register new handlers in ``CODEGEN_HANDLERS``
keyed by ``RuntimeOp.codegen``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Sequence, Tuple

import torch.fx as fx

from .memory import (
    BufferLayout,
    BufferMaterializer,
    ElementType,
    MemoryPlan,
    StaticBuffer,
    format_shape,
)
from .memory.dram import DramImage
from .memory.gemm_tiles import (
    SCRATCH_CAP_BYTES,
    STREAM_ACT_CAP,
    choose_conv_tiles,
    choose_stream_conv_nest,
    choose_tile,
    conv_spatial_tiles,
    matmul_out_shape,
    numel,
    scratch_budget,
    stream_act_fits,
    tile_scratch_bytes,
)
from .registry import RegistryError, RuntimeOp

I32 = ElementType(c_type="int32_t", size_bytes=4)


def _c_ident(node: fx.Node, suffix: str) -> str:
    base = node.name.replace("%", "v_").replace(".", "_")
    return f"_{base}_{suffix}"


def _with_static_tables(
    tables: Sequence[Tuple[str, str, str]], call: str
) -> str:
    """Static arrays instead of compound literals.

    GCC ``-march=rv32im_zve32x -O0`` memcpy's 16-byte compound literals with
    ``vle8``/``vse8``, which this Zve32x box does not implement (SEW=32 only).
    """
    decls = [
        f"static const {ctype} {name}[] = {{ {vals} }};"
        for ctype, name, vals in tables
    ]
    return "{\n    " + "\n    ".join(decls + [call]) + "\n}"


@dataclass
class LoweringCtx:
    memory: MemoryPlan
    buf: Dict[str, str]
    shape: Dict[str, Tuple[int, ...]]
    tuples: Dict[str, List[str]]
    gemm_scratch_bytes: int | None
    graph_module: Any
    materializer: BufferMaterializer
    scratch_id: int = 0
    stream: bool = False
    dram_image: DramImage | None = None
    stream_col_n: int = 0
    stream_col_cache_n: int = 0
    stream_wt_n: int = 0
    stream_acc_n: int = 0
    stream_gemm_n: int = 0
    stream_need_stage: bool = False
    stream_act_n: int = 0

    def cname(self, node: fx.Node) -> str:
        try:
            return self.buf[node.name]
        except KeyError as exc:
            raise RegistryError(f"Missing buffer for FX node {node.name}") from exc

    def logical_shape(self, node: fx.Node) -> Tuple[int, ...]:
        try:
            return self.shape[node.name]
        except KeyError as exc:
            raise RegistryError(f"Missing shape for FX node {node.name}") from exc

    def alloc(self, fx_name: str, shape: Sequence[int]) -> str:
        cname = fx_name.replace("%", "v_")
        shp = tuple(int(d) for d in shape)
        n = 1
        for dim in shp:
            n *= int(dim)
        if self.stream and self.dram_image is not None:
            off = self.dram_image.alloc(n * 4)
            self.memory.add(
                StaticBuffer(
                    name=cname,
                    shape=shp,
                    element=I32,
                    layout=BufferLayout.dram_buffer(n, off, elem_bytes=4),
                )
            )
        else:
            self.memory.allocate_shape(cname, shp)
        self.buf[fx_name] = cname
        self.shape[fx_name] = shp
        return cname

    def alias(self, fx_name: str, src_fx: str, shape: Sequence[int]) -> str:
        cname = self.buf[src_fx]
        self.buf[fx_name] = cname
        self.shape[fx_name] = tuple(int(d) for d in shape)
        return cname

    def scratch(self, nbytes: int) -> str:
        self.scratch_id += 1
        name = f"scratch_{self.scratch_id}"
        self.memory.add(
            StaticBuffer(
                name=name,
                shape=(nbytes,),
                element=ElementType(c_type="uint8_t", size_bytes=1),
                layout=BufferLayout.flat_row_major(nbytes),
            )
        )
        return name

    def note_stream_conv(
        self,
        col_n: int,
        wt_n: int,
        acc_n: int,
        gemm_n: int,
        *,
        cache: bool = False,
    ) -> None:
        if cache:
            self.stream_col_cache_n = max(self.stream_col_cache_n, int(col_n))
        else:
            self.stream_col_n = max(self.stream_col_n, int(col_n))
        self.stream_wt_n = max(self.stream_wt_n, int(wt_n))
        self.stream_acc_n = max(self.stream_acc_n, int(acc_n))
        self.stream_gemm_n = max(self.stream_gemm_n, int(gemm_n))

    def note_stream_act(self, n: int) -> None:
        self.stream_act_n = max(self.stream_act_n, int(n))


def _buffer_name(node: fx.Node) -> str:
    return node.name.replace("%", "v_")


def _as_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return int(value)
    raise RegistryError(f"Expected int, got {type(value)}")


def _as_ints(value: Any) -> List[int]:
    if isinstance(value, (int, float, bool)):
        return [_as_int(value)]
    if isinstance(value, (list, tuple)):
        return [_as_int(v) for v in value]
    raise RegistryError(f"Expected int list, got {type(value)}")


def _norm_dim(dim: int, rank: int) -> int:
    if dim < 0:
        dim += rank
    if dim < 0 or dim >= rank:
        raise RegistryError(f"dim {dim} out of range for rank {rank}")
    return dim


def _infer_view(numel_in: int, shape: Sequence[int]) -> Tuple[int, ...]:
    dims = [int(s) for s in shape]
    if dims.count(-1) > 1:
        raise RegistryError(f"view shape has more than one -1: {shape}")
    if -1 in dims:
        known = 1
        for s in dims:
            if s != -1:
                known *= s
        if known == 0 or numel_in % known != 0:
            raise RegistryError(f"cannot infer view {shape} from numel {numel_in}")
        dims[dims.index(-1)] = numel_in // known
    out_n = 1
    for s in dims:
        if s < 0:
            raise RegistryError(f"negative view dim in {dims}")
        out_n *= s
    if out_n != numel_in:
        raise RegistryError(f"view numel {out_n} != {numel_in}")
    return tuple(dims)


def _broadcast_shapes(
    a: Sequence[int], b: Sequence[int]
) -> Tuple[Tuple[int, ...], Tuple[int, ...], Tuple[int, ...]]:
    rank = max(len(a), len(b))
    a_p = (1,) * (rank - len(a)) + tuple(int(d) for d in a)
    b_p = (1,) * (rank - len(b)) + tuple(int(d) for d in b)
    out: List[int] = []
    for da, db in zip(a_p, b_p):
        if da != db and da != 1 and db != 1:
            raise RegistryError(f"cannot broadcast {tuple(a)} vs {tuple(b)}")
        out.append(max(da, db))
    return tuple(out), a_p, b_p


def _node_meta_shape(node: fx.Node) -> Tuple[int, ...] | None:
    val = node.meta.get("val") if node.meta else None
    if hasattr(val, "shape"):
        return tuple(int(d) for d in val.shape)
    return None


def emit_elementwise_binary(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    if len(node.args) != 2:
        raise RegistryError(
            f"{op.graph_target} expects two operands (node {node.name})"
        )
    return _emit_binary(op, node, ctx, op_kind="mul" if "mul" in op.graph_target else (
        "sub" if "sub" in op.graph_target else "add"
    ))


def emit_div_trunc(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    mode = node.kwargs.get("rounding_mode", None)
    if mode not in (None, "trunc"):
        raise RegistryError(
            f"{op.graph_target} only supports trunc rounding (got {mode})"
        )
    return _emit_binary(op, node, ctx, op_kind="div")


def _c_binop(kind: str, lhs: str, rhs: str) -> str:
    if kind == "add":
        return f"{lhs} + {rhs}"
    if kind == "sub":
        return f"{lhs} - {rhs}"
    if kind == "mul":
        return f"{lhs} * {rhs}"
    if kind == "div":
        return f"{lhs} / {rhs}"
    raise RegistryError(f"unknown binop {kind}")


def _emit_binary(
    op: RuntimeOp, node: fx.Node, ctx: LoweringCtx, *, op_kind: str
) -> str:
    lhs_arg, rhs_arg = node.args[0], node.args[1]
    out_meta = _node_meta_shape(node)

    if isinstance(lhs_arg, fx.Node) and isinstance(rhs_arg, fx.Node):
        lhs = ctx.cname(lhs_arg)
        rhs = ctx.cname(rhs_arg)
        ls = ctx.logical_shape(lhs_arg)
        rs = ctx.logical_shape(rhs_arg)
        if ls == rs:
            out = ctx.alloc(node.name, ls)
            n = numel(ls)
            if op_kind == "div":
                return f"{op.symbol}({lhs}, {rhs}, {out}, {n});"
            return f"{op.symbol}({lhs}, {rhs}, {out}, {n});"
        out_shape, a_p, b_p = _broadcast_shapes(ls, rs)
        if out_meta is not None and out_meta != out_shape:
            out_shape = out_meta
        out = ctx.alloc(node.name, out_shape)
        return _emit_broadcast_loop(op_kind, lhs, rhs, out, a_p, b_p, out_shape)

    if isinstance(lhs_arg, fx.Node) and not isinstance(rhs_arg, fx.Node):
        lhs = ctx.cname(lhs_arg)
        ls = ctx.logical_shape(lhs_arg)
        scalar = _as_int(rhs_arg)
        out = ctx.alloc(node.name, out_meta or ls)
        n = numel(out_meta or ls)
        expr = _c_binop(op_kind, f"{lhs}[i]", str(scalar))
        return (
            "{\n"
            f"    for (size_t i = 0; i < {n}; i++) {{\n"
            f"        {out}[i] = {expr};\n"
            "    }\n"
            "}"
        )

    if isinstance(rhs_arg, fx.Node) and not isinstance(lhs_arg, fx.Node):
        rhs = ctx.cname(rhs_arg)
        rs = ctx.logical_shape(rhs_arg)
        scalar = _as_int(lhs_arg)
        out = ctx.alloc(node.name, out_meta or rs)
        n = numel(out_meta or rs)
        expr = _c_binop(op_kind, str(scalar), f"{rhs}[i]")
        return (
            "{\n"
            f"    for (size_t i = 0; i < {n}; i++) {{\n"
            f"        {out}[i] = {expr};\n"
            "    }\n"
            "}"
        )

    raise RegistryError(f"{op.graph_target}: unsupported operands (node {node.name})")


def _emit_broadcast_loop(
    kind: str,
    a: str,
    b: str,
    out: str,
    a_shape: Sequence[int],
    b_shape: Sequence[int],
    out_shape: Sequence[int],
) -> str:
    rank = len(out_shape)
    coords = [f"i{d}" for d in range(rank)]
    lines = ["{"]
    indent = 1

    def add(s: str) -> None:
        lines.append("    " * indent + s)

    for d, dim in enumerate(out_shape):
        add(f"for (size_t {coords[d]} = 0; {coords[d]} < {int(dim)}; {coords[d]}++) {{")
        indent += 1

    def offset(shape: Sequence[int]) -> str:
        terms: List[str] = []
        stride = 1
        for d in range(rank - 1, -1, -1):
            if shape[d] != 1:
                terms.append(f"{coords[d]} * {stride}")
            stride *= int(shape[d])
        return " + ".join(reversed(terms)) if terms else "0"

    expr = _c_binop(kind, f"{a}[{offset(a_shape)}]", f"{b}[{offset(b_shape)}]")
    add(f"{out}[{offset(out_shape)}] = {expr};")
    for _ in out_shape:
        indent -= 1
        add("}")
    lines.append("}")
    return "\n".join(lines)


def emit_unary_same(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    if len(node.args) < 1 or not isinstance(node.args[0], fx.Node):
        raise RegistryError(f"{op.graph_target} expects a tensor (node {node.name})")
    src = ctx.cname(node.args[0])
    shp = ctx.logical_shape(node.args[0])
    out = ctx.alloc(node.name, _node_meta_shape(node) or shp)
    n = numel(_node_meta_shape(node) or shp)
    if ctx.stream:
        ctx.stream_need_stage = True
        return _stage_unary(op.symbol, src, out, n)
    return f"{op.symbol}({src}, {out}, {n});"


DCCM_SLAB = 32768


# Matches ``aten_max_pool2d.c`` RVV rowmax[] / ``w <= 64``.
POOL_RVV_MAX_W = 64


def choose_pool_stream_tiles(
    c: int,
    h: int,
    w: int,
    oh: int,
    ow: int,
    kh: int,
    kw: int,
    sh: int,
    sw: int,
    *,
    slab: int = DCCM_SLAB,
    max_w_span: int = POOL_RVV_MAX_W,
) -> tuple[int, int, int] | None:
    """``(c_t, oh_t, ow_t)`` so one pad-0 window fits ``slab`` and RVV ``W``."""
    del h, w
    if (
        c < 1
        or oh < 1
        or ow < 1
        or kh < 1
        or kw < 1
        or sh < 1
        or sw < 1
        or slab < 1
        or max_w_span < 1
    ):
        return None
    ow_hi = min(ow, max(1, (max_w_span - kw) // sw + 1))
    for ow_t in range(ow_hi, 0, -1):
        w_span = (ow_t - 1) * sw + kw
        if w_span < 1 or w_span > max_w_span:
            continue
        for oh_t in range(oh, 0, -1):
            h_span = (oh_t - 1) * sh + kh
            inn_c = h_span * w_span
            onn_c = oh_t * ow_t
            if inn_c < 1 or onn_c < 1 or inn_c > slab or onn_c > slab:
                continue
            c_t = min(c, slab // inn_c, slab // onn_c)
            if c_t >= 1:
                return c_t, oh_t, ow_t
    return None


def _stage_unary(symbol: str, src: str, out: str, n: int) -> str:
    return (
        "{\n"
        f"    const size_t slab = {DCCM_SLAB};\n"
        f"    for (size_t off = 0; off < {n}; off += slab) {{\n"
        "        size_t m = " + str(n) + " - off;\n"
        "        if (m > slab) { m = slab; }\n"
        f"        pyvedas_memcpy(stream_stage_a, {src} + off, m * sizeof(int32_t));\n"
        f"        {symbol}(stream_stage_a, stream_stage_b, m);\n"
        f"        pyvedas_memcpy({out} + off, stream_stage_b, m * sizeof(int32_t));\n"
        "    }\n"
        "}"
    )


def emit_alias(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    del op
    src = node.args[0]
    if not isinstance(src, fx.Node):
        raise RegistryError(f"alias expects a tensor (node {node.name})")
    shp = _node_meta_shape(node) or ctx.logical_shape(src)
    ctx.alias(node.name, src.name, shp)
    return f"/* alias {node.name} -> {ctx.buf[src.name]} shape={format_shape(shp)} */"


def emit_view(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    del op
    src = node.args[0]
    if not isinstance(src, fx.Node):
        raise RegistryError(f"view expects a tensor (node {node.name})")
    want = _as_ints(node.args[1])
    shp = _infer_view(numel(ctx.logical_shape(src)), want)
    ctx.alias(node.name, src.name, shp)
    return f"/* view {node.name} -> {ctx.buf[src.name]} shape={format_shape(shp)} */"


def emit_getitem(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    del op
    src, idx = node.args[0], _as_int(node.args[1])
    if not isinstance(src, fx.Node):
        raise RegistryError(f"getitem expects a tuple node (node {node.name})")
    parts = ctx.tuples.get(src.name)
    if parts is None:
        raise RegistryError(f"getitem source {src.name} is not a tuple")
    if idx < 0 or idx >= len(parts):
        raise RegistryError(f"getitem index {idx} out of range for {src.name}")
    src_fx = parts[idx]
    ctx.buf[node.name] = ctx.buf[src_fx]
    ctx.shape[node.name] = ctx.shape[src_fx]
    return f"/* getitem {node.name} = {src.name}[{idx}] -> {ctx.buf[src_fx]} */"


def emit_arange(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    end = _as_int(node.args[0])
    out = ctx.alloc(node.name, (end,))
    return f"{op.symbol}({out}, {end});"


def emit_meshgrid(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    indexing = node.kwargs.get("indexing", "ij")
    if indexing != "ij":
        raise RegistryError(f"meshgrid only supports indexing='ij' (node {node.name})")
    tensors = node.args[0]
    if not isinstance(tensors, (list, tuple)) or len(tensors) != 2:
        raise RegistryError("meshgrid expects two 1-D tensors")
    a, b = tensors
    if not isinstance(a, fx.Node) or not isinstance(b, fx.Node):
        raise RegistryError("meshgrid args must be FX nodes")
    ha = numel(ctx.logical_shape(a))
    wb = numel(ctx.logical_shape(b))
    gy = ctx.alloc(f"{node.name}_0", (ha, wb))
    gx = ctx.alloc(f"{node.name}_1", (ha, wb))
    ctx.tuples[node.name] = [f"{node.name}_0", f"{node.name}_1"]
    ctx.buf[node.name] = gy
    ctx.shape[node.name] = (ha, wb)
    return (
        f"{op.symbol}({ctx.cname(a)}, {ctx.cname(b)}, {gy}, {gx}, {ha}, {wb});"
    )


def emit_stack(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    tensors = node.args[0]
    dim = _as_int(node.args[1]) if len(node.args) > 1 else 0
    if not isinstance(tensors, (list, tuple)) or not tensors:
        raise RegistryError("stack expects a non-empty list of tensors")
    shapes = [ctx.logical_shape(t) for t in tensors if isinstance(t, fx.Node)]
    if len(shapes) != len(tensors):
        raise RegistryError("stack args must be FX nodes")
    if any(s != shapes[0] for s in shapes):
        raise RegistryError("stack requires matching shapes")
    dim = _norm_dim(dim, len(shapes[0]) + 1)
    out_shape = shapes[0][:dim] + (len(tensors),) + shapes[0][dim:]
    out = ctx.alloc(node.name, _node_meta_shape(node) or out_shape)
    names = ", ".join(ctx.cname(t) for t in tensors if isinstance(t, fx.Node))
    inner = numel(shapes[0][dim:]) if dim < len(shapes[0]) else 1
    outer = numel(shapes[0][:dim])
    n = len(tensors)
    ins = _c_ident(node, "ins")
    return _with_static_tables(
        [("int32_t *", ins, names)],
        f"{op.symbol}({ins}, {out}, {n}, {outer}, {inner});",
    )


def emit_cat(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    tensors = node.args[0]
    dim = _as_int(node.args[1]) if len(node.args) > 1 else 0
    if not isinstance(tensors, (list, tuple)) or not tensors:
        raise RegistryError("cat expects a non-empty list of tensors")
    nodes = [t for t in tensors if isinstance(t, fx.Node)]
    shapes = [ctx.logical_shape(t) for t in nodes]
    dim = _norm_dim(dim, len(shapes[0]))
    out_shape = list(shapes[0])
    out_shape[dim] = sum(s[dim] for s in shapes)
    out = ctx.alloc(node.name, _node_meta_shape(node) or tuple(out_shape))
    names = ", ".join(ctx.cname(t) for t in nodes)
    dim_sizes = ", ".join(str(s[dim]) for s in shapes)
    inner = numel(shapes[0][dim + 1 :])
    outer = numel(shapes[0][:dim])
    n = len(nodes)
    ins = _c_ident(node, "ins")
    dims = _c_ident(node, "dim_sizes")
    return _with_static_tables(
        [("int32_t *", ins, names), ("size_t", dims, dim_sizes)],
        f"{op.symbol}({ins}, {dims}, {out}, {n}, {outer}, {inner});",
    )


def emit_pad(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    pad = _as_ints(node.args[1])
    value = 0
    if len(node.args) >= 4:
        value = _as_int(node.args[3])
    if not isinstance(src, fx.Node):
        raise RegistryError("pad expects a tensor")
    if len(pad) % 2 != 0:
        raise RegistryError(f"pad spec length must be even, got {pad}")
    shp = list(ctx.logical_shape(src))
    rank = len(shp)
    ndims = len(pad) // 2
    # F.pad: last dim first (W then H for NCHW).
    for i in range(ndims):
        left = pad[2 * i]
        right = pad[2 * i + 1]
        dim = rank - 1 - i
        shp[dim] = shp[dim] + left + right
    out = ctx.alloc(node.name, _node_meta_shape(node) or tuple(shp))
    in_shape = ctx.logical_shape(src)
    in_s = ", ".join(str(d) for d in in_shape)
    out_s = ", ".join(str(d) for d in (_node_meta_shape(node) or tuple(shp)))
    pad_s = ", ".join(str(p) for p in pad)
    in_name = _c_ident(node, "in_shape")
    out_name = _c_ident(node, "out_shape")
    pad_name = _c_ident(node, "pad")
    return _with_static_tables(
        [
            ("size_t", in_name, in_s),
            ("size_t", out_name, out_s),
            ("int", pad_name, pad_s),
        ],
        f"{op.symbol}({ctx.cname(src)}, {out}, {rank}, "
        f"{in_name}, {out_name}, {len(pad)}, {pad_name}, {value});",
    )


def emit_permute(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    dims = _as_ints(node.args[1])
    if not isinstance(src, fx.Node):
        raise RegistryError("permute expects a tensor")
    in_shape = ctx.logical_shape(src)
    if len(dims) != len(in_shape):
        raise RegistryError("permute rank mismatch")
    out_shape = tuple(in_shape[d] for d in dims)
    out = ctx.alloc(node.name, _node_meta_shape(node) or out_shape)
    in_s = ", ".join(str(d) for d in in_shape)
    dim_s = ", ".join(str(d) for d in dims)
    in_name = _c_ident(node, "in_shape")
    dim_name = _c_ident(node, "dims")
    return _with_static_tables(
        [("size_t", in_name, in_s), ("int", dim_name, dim_s)],
        f"{op.symbol}({ctx.cname(src)}, {out}, {len(dims)}, "
        f"{in_name}, {dim_name});",
    )


def emit_slice(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    dim = _as_int(node.args[1])
    start = _as_int(node.args[2]) if len(node.args) > 2 and node.args[2] is not None else 0
    end = node.args[3] if len(node.args) > 3 else None
    step = _as_int(node.args[4]) if len(node.args) > 4 and node.args[4] is not None else 1
    if not isinstance(src, fx.Node):
        raise RegistryError("slice expects a tensor")
    in_shape = ctx.logical_shape(src)
    dim = _norm_dim(dim, len(in_shape))
    dim_n = in_shape[dim]
    if end is None:
        end_i = dim_n
    else:
        end_i = _as_int(end)
        if end_i > 10**15:
            end_i = dim_n
    if start < 0:
        start += dim_n
    if end_i < 0:
        end_i += dim_n
    start = max(0, min(start, dim_n))
    end_i = max(0, min(end_i, dim_n))
    if step != 1:
        raise RegistryError("slice step != 1 is not supported")
    out_shape = list(in_shape)
    out_shape[dim] = max(0, end_i - start)
    out = ctx.alloc(node.name, _node_meta_shape(node) or tuple(out_shape))
    in_s = ", ".join(str(d) for d in in_shape)
    in_name = _c_ident(node, "in_shape")
    return _with_static_tables(
        [("size_t", in_name, in_s)],
        f"{op.symbol}({ctx.cname(src)}, {out}, {len(in_shape)}, "
        f"{in_name}, {dim}, {start}, {end_i});",
    )


def emit_select(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    dim = _as_int(node.args[1])
    index = _as_int(node.args[2])
    if not isinstance(src, fx.Node):
        raise RegistryError("select expects a tensor")
    in_shape = ctx.logical_shape(src)
    dim = _norm_dim(dim, len(in_shape))
    if index < 0:
        index += in_shape[dim]
    out_shape = in_shape[:dim] + in_shape[dim + 1 :]
    out = ctx.alloc(node.name, _node_meta_shape(node) or out_shape)
    in_s = ", ".join(str(d) for d in in_shape)
    in_name = _c_ident(node, "in_shape")
    return _with_static_tables(
        [("size_t", in_name, in_s)],
        f"{op.symbol}({ctx.cname(src)}, {out}, {len(in_shape)}, "
        f"{in_name}, {dim}, {index});",
    )


def emit_max_pool2d(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    k = _as_ints(node.args[1])
    kh, kw = (k[0], k[0]) if len(k) == 1 else (k[0], k[1])
    if len(node.args) > 2:
        st = _as_ints(node.args[2])
        sh, sw = (st[0], st[0]) if len(st) == 1 else (st[0], st[1])
    else:
        sh, sw = kh, kw
    pad_h = pad_w = 0
    if len(node.args) > 3:
        pd = _as_ints(node.args[3])
        pad_h, pad_w = (pd[0], pd[0]) if len(pd) == 1 else (pd[0], pd[1])
    if not isinstance(src, fx.Node):
        raise RegistryError("max_pool2d expects a tensor")
    n, c, h, w = ctx.logical_shape(src)
    oh = (h + 2 * pad_h - kh) // sh + 1
    ow = (w + 2 * pad_w - kw) // sw + 1
    out = ctx.alloc(node.name, _node_meta_shape(node) or (n, c, oh, ow))
    call = (
        f"{op.symbol}(%s, %s, {n}, {c}, {h}, {w}, "
        f"{oh}, {ow}, {kh}, {kw}, {sh}, {sw}, {pad_h}, {pad_w});"
    )
    inn = n * c * h * w
    onn = n * c * oh * ow
    # Whole map in one DCCM slab (RVV path wants W<=64 and DCCM pointers).
    if ctx.stream and pad_h == 0 and pad_w == 0 and inn <= DCCM_SLAB and onn <= DCCM_SLAB:
        ctx.stream_need_stage = True
        return (
            "{\n"
            f"    pyvedas_memcpy(stream_stage_a, {ctx.cname(src)}, {inn} * sizeof(int32_t));\n"
            "    " + call % ("stream_stage_a", "stream_stage_b") + "\n"
            f"    pyvedas_memcpy({out}, stream_stage_b, {onn} * sizeof(int32_t));\n"
            "}"
        )
    # Wide / tall maps (Tiny c0 is 16x208x208) cannot walk the AXI stub.
    # Keep W_span <= 64 so aten_max_pool2d takes the DCCM RVV path.
    if ctx.stream and pad_h == 0 and pad_w == 0:
        tiles = choose_pool_stream_tiles(c, h, w, oh, ow, kh, kw, sh, sw)
        if tiles is not None:
            ctx.stream_need_stage = True
            c_t, oh_t, ow_t = tiles
            src_n = ctx.cname(src)
            tiled = (
                f"{op.symbol}(stream_stage_a, stream_stage_b, 1, ct, hs, "
                f"ws, oht, owt, {kh}, {kw}, {sh}, {sw}, {pad_h}, {pad_w});"
            )
            return (
                "{\n"
                f"    const size_t c_t = {c_t};\n"
                f"    const size_t oh_t = {oh_t};\n"
                f"    const size_t ow_t = {ow_t};\n"
                f"    for (size_t ni = 0; ni < {n}; ni++) {{\n"
                f"    for (size_t ci0 = 0; ci0 < {c}; ci0 += c_t) {{\n"
                f"        size_t ct = {c} - ci0;\n"
                "        if (ct > c_t) { ct = c_t; }\n"
                f"        for (size_t oy0 = 0; oy0 < {oh}; oy0 += oh_t) {{\n"
                f"            size_t oht = {oh} - oy0;\n"
                "            if (oht > oh_t) { oht = oh_t; }\n"
                f"            size_t h0 = oy0 * {sh};\n"
                f"            size_t hs = (oht - 1) * {sh} + {kh};\n"
                f"            if (h0 + hs > {h}) {{ hs = {h} - h0; }}\n"
                f"            for (size_t ox0 = 0; ox0 < {ow}; ox0 += ow_t) {{\n"
                f"                size_t owt = {ow} - ox0;\n"
                "                if (owt > ow_t) { owt = ow_t; }\n"
                f"                size_t w0 = ox0 * {sw};\n"
                f"                size_t ws = (owt - 1) * {sw} + {kw};\n"
                f"                if (w0 + ws > {w}) {{ ws = {w} - w0; }}\n"
                "                for (size_t t = 0; t < ct; t++) {\n"
                "                    for (size_t r = 0; r < hs; r++) {\n"
                f"                        pyvedas_memcpy(stream_stage_a + (t * hs + r) * ws,\n"
                f"                            {src_n} + (((ni * {c} + (ci0 + t)) * {h} + h0 + r) * {w} + w0),\n"
                "                            ws * sizeof(int32_t));\n"
                "                    }\n"
                "                }\n"
                f"                {tiled}\n"
                "                for (size_t t = 0; t < ct; t++) {\n"
                "                    for (size_t r = 0; r < oht; r++) {\n"
                f"                        pyvedas_memcpy({out} + (((ni * {c} + (ci0 + t)) * {oh} + oy0 + r) * {ow} + ox0),\n"
                "                            stream_stage_b + (t * oht + r) * owt,\n"
                "                            owt * sizeof(int32_t));\n"
                "                    }\n"
                "                }\n"
                "            }\n"
                "        }\n"
                "    }\n"
                "    }\n"
                "}"
            )
    return call % (ctx.cname(src), out)


def emit_upsample_nearest(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    if not isinstance(src, fx.Node):
        raise RegistryError("upsample_nearest expects a tensor")
    n, c, h, w = ctx.logical_shape(src)
    out_size = node.args[1] if len(node.args) > 1 else None
    scales = node.args[2] if len(node.args) > 2 else None
    if out_size is not None:
        oh, ow = _as_ints(out_size)
    elif scales is not None:
        sh, sw = scales[0], scales[1]
        oh = int(h * float(sh))
        ow = int(w * float(sw))
    else:
        raise RegistryError("upsample_nearest needs output_size or scales")
    out = ctx.alloc(node.name, _node_meta_shape(node) or (n, c, oh, ow))
    return (
        f"{op.symbol}({ctx.cname(src)}, {out}, {n}, {c}, {h}, {w}, {oh}, {ow});"
    )


def emit_upsample_bilinear(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    oh = _as_int(node.args[1])
    ow = _as_int(node.args[2])
    if not isinstance(src, fx.Node):
        raise RegistryError("upsample_bilinear expects a tensor")
    n, c, h, w = ctx.logical_shape(src)
    out = ctx.alloc(node.name, _node_meta_shape(node) or (n, c, oh, ow))
    return (
        f"{op.symbol}({ctx.cname(src)}, {out}, {n}, {c}, {h}, {w}, {oh}, {ow});"
    )


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
    *,
    scratch_name: str | None = None,
    declare_scratch: bool = True,
) -> Tuple[str, int]:
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
    scratch = scratch_name or f"scratch_{out}"
    coords = [f"b{i}" for i in range(len(out_batch))]
    a_off = _batch_offset_expr(coords, a_batch, out_batch, m * k)
    b_off = _batch_offset_expr(coords, b_batch, out_batch, k * n)
    c_off = _batch_offset_expr(coords, out_batch, out_batch, m * n)

    lines: List[str] = ["{"]
    if declare_scratch:
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
    return "\n".join(lines), scratch_bytes


def emit_gemm_mmio(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    memory = ctx.memory
    if len(node.args) != 2:
        raise RegistryError(
            f"{op.graph_target} expects A, B (node {node.name})"
        )

    lhs_node, rhs_node = node.args[0], node.args[1]
    if not isinstance(lhs_node, fx.Node) or not isinstance(rhs_node, fx.Node):
        raise RegistryError(f"{op.graph_target} expects tensor A, B")
    lhs = ctx.cname(lhs_node)
    rhs = ctx.cname(rhs_node)
    lhs_shape = ctx.logical_shape(lhs_node)
    rhs_shape = ctx.logical_shape(rhs_node)

    if len(lhs_shape) < 2 or len(rhs_shape) < 2:
        raise RegistryError(f"{op.graph_target} requires rank >= 2 A and B")

    try:
        out_shape = matmul_out_shape(lhs_shape, rhs_shape)
    except ValueError as exc:
        raise RegistryError(f"{op.graph_target}: {exc}") from exc

    out = ctx.alloc(node.name, out_shape)
    cap = (
        SCRATCH_CAP_BYTES
        if ctx.gemm_scratch_bytes is None
        else int(ctx.gemm_scratch_bytes)
    )
    block, _nbytes = emit_gemm_c(
        op.symbol,
        lhs,
        rhs,
        out,
        lhs_shape,
        rhs_shape,
        cap,
    )
    return block


def emit_conv2d(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    x_n, w_n, b_n, stride, padding = node.args
    if not all(isinstance(t, fx.Node) for t in (x_n, w_n, b_n)):
        raise RegistryError("conv2d expects tensor x, weight, bias")
    stride_i = _as_int(stride)
    pad_i = _as_int(padding)
    n, cin, h, w = ctx.logical_shape(x_n)
    cout, cin_w, kh, kw = ctx.logical_shape(w_n)
    if cin != cin_w:
        raise RegistryError(f"conv2d Cin mismatch {cin} vs {cin_w}")
    oh = (h + 2 * pad_i - kh) // stride_i + 1
    ow = (w + 2 * pad_i - kw) // stride_i + 1
    m = n * oh * ow
    kdim = cin * kh * kw
    out = ctx.alloc(node.name, _node_meta_shape(node) or (n, cout, oh, ow))
    cap = (
        SCRATCH_CAP_BYTES
        if ctx.gemm_scratch_bytes is None
        else int(ctx.gemm_scratch_bytes)
    )
    if ctx.stream:
        return _emit_conv2d_stream(
            ctx, node, x_n, w_n, b_n, n, cin, cout, h, w, kh, kw,
            stride_i, pad_i, oh, ow, m, kdim, out, cap,
        )
    col = ctx.alloc(f"{node.name}_col", (m, kdim))
    wt = ctx.alloc(f"{node.name}_wt", (kdim, cout))
    gemm = ctx.alloc(f"{node.name}_gemm", (m, cout))
    gemm_block, _nbytes = emit_gemm_c(
        "pyvedas_gemm_job", col, wt, gemm, (m, kdim), (kdim, cout), cap
    )
    return (
        "{\n"
        f"    pyvedas_im2col({ctx.cname(x_n)}, {col}, {n}, {cin}, {h}, {w}, "
        f"{kh}, {kw}, {stride_i}, {pad_i}, {oh}, {ow});\n"
        f"    pyvedas_pack_weight_crs({ctx.cname(w_n)}, {wt}, {cout}, {cin}, "
        f"{kh}, {kw});\n"
        + "\n".join("    " + ln if ln else "" for ln in gemm_block.split("\n"))
        + "\n"
        f"    pyvedas_conv_bias_nchw({gemm}, {ctx.cname(b_n)}, {out}, "
        f"{n}, {cout}, {oh}, {ow});\n"
        "}"
    )


def _emit_conv2d_stream(
    ctx: LoweringCtx,
    node: fx.Node,
    x_n: fx.Node,
    w_n: fx.Node,
    b_n: fx.Node,
    n: int,
    cin: int,
    cout: int,
    h: int,
    w: int,
    kh: int,
    kw: int,
    stride_i: int,
    pad_i: int,
    oh: int,
    ow: int,
    m: int,
    kdim: int,
    out: str,
    cap: int,
) -> str:
    del m
    oh_t, ow_t, oc_t = choose_conv_tiles(n, cin, cout, kh, kw, oh, ow)
    m_t = n * oh_t * ow_t
    wbuf = ctx.memory.get(ctx.cname(w_n))
    pack = (
        "pyvedas_pack_weight_i8_crs_tile"
        if wbuf.element.c_type == "int8_t"
        else "pyvedas_pack_weight_crs_tile"
    )
    x_dram = ctx.cname(x_n)
    act_n = n * cin * h * w
    nest = choose_stream_conv_nest(
        oh, ow, oh_t, ow_t, cout, oc_t, m_t, kdim,
        act_n=0,
    )
    spatial = max(conv_spatial_tiles(oh, ow, oh_t, ow_t), 1)
    col_tile = max(m_t * kdim, 1)
    col_n = col_tile * spatial if nest == "cache_col" else col_tile
    # cache_col keeps every spatial col tile; do not also stage the map
    # (act+col together miss the 1 MiB DCCM).
    stage_act = nest != "cache_col" and stream_act_fits(
        n, cin, h, w, cap=STREAM_ACT_CAP
    )
    gemm_block, gemm_n = emit_gemm_c(
        "pyvedas_gemm_job",
        "stream_col_as",
        "stream_wt",
        "stream_acc",
        (m_t, kdim),
        (kdim, oc_t),
        cap,
        scratch_name="stream_gemm_scratch",
        declare_scratch=False,
    )
    ctx.note_stream_conv(
        col_n,
        max(kdim * oc_t, 1),
        max(m_t * oc_t, 1),
        gemm_n,
        cache=nest == "cache_col",
    )
    if stage_act:
        ctx.note_stream_act(act_n)
        x_src = "stream_act"
        stage_stmt = (
            f"    pyvedas_memcpy(stream_act, {x_dram}, "
            f"{act_n} * sizeof(int32_t));\n"
        )
    else:
        x_src = x_dram
        stage_stmt = ""
    im2col_dst = (
        "stream_col_cache + si * col_tile"
        if nest == "cache_col"
        else "stream_col"
    )
    im2col = (
        f"pyvedas_im2col_tile({x_src}, {im2col_dst}, {n}, {cin}, {h}, {w}, "
        f"{kh}, {kw}, {stride_i}, {pad_i}, {oh}, {ow}, oh0, ow0, oh_t, ow_t);"
    )
    pack_call = (
        f"{pack}({ctx.cname(w_n)}, stream_wt, {cout}, {cin}, {kh}, {kw}, "
        f"oc0, oc_t);"
    )
    bias = (
        f"pyvedas_conv_bias_nchw_tile(stream_acc, {ctx.cname(b_n)}, {out}, "
        f"{n}, {cout}, {oh}, {ow}, oh0, ow0, oh_t, ow_t, oc0, oc_t);"
    )
    gemm_inner = "\n".join(
        "            " + ln if ln else "" for ln in gemm_block.split("\n")
    )
    header = (
        "{\n"
        f"    const size_t oh_t = {oh_t};\n"
        f"    const size_t ow_t = {ow_t};\n"
        f"    const size_t oc_t = {oc_t};\n"
        + stage_stmt
    )
    if nest == "cache_col":
        gemm_cached = "\n".join(
            "                " + ln if ln else "" for ln in gemm_block.split("\n")
        )
        return (
            header
            + f"    const size_t col_tile = {col_tile};\n"
            + "    size_t si = 0;\n"
            + f"    for (size_t oh0 = 0; oh0 < {oh}; oh0 += oh_t) {{\n"
            + f"    for (size_t ow0 = 0; ow0 < {ow}; ow0 += ow_t) {{\n"
            + f"        {im2col}\n"
            + "        si++;\n"
            + "    }\n"
            + "    }\n"
            + f"    for (size_t oc0 = 0; oc0 < {cout}; oc0 += oc_t) {{\n"
            + f"        {pack_call}\n"
            + "        si = 0;\n"
            + f"        for (size_t oh0 = 0; oh0 < {oh}; oh0 += oh_t) {{\n"
            + f"        for (size_t ow0 = 0; ow0 < {ow}; ow0 += ow_t) {{\n"
            + "            const int32_t *stream_col_as = stream_col_cache + si * col_tile;\n"
            + gemm_cached
            + "\n"
            + f"            {bias}\n"
            + "            si++;\n"
            + "        }\n"
            + "        }\n"
            + "    }\n"
            + "}"
        )
    if nest == "spatial_outer":
        return (
            header
            + f"    for (size_t oh0 = 0; oh0 < {oh}; oh0 += oh_t) {{\n"
            + f"    for (size_t ow0 = 0; ow0 < {ow}; ow0 += ow_t) {{\n"
            + f"        {im2col}\n"
            + f"        for (size_t oc0 = 0; oc0 < {cout}; oc0 += oc_t) {{\n"
            + f"            {pack_call}\n"
            + "            const int32_t *stream_col_as = stream_col;\n"
            + gemm_inner
            + "\n"
            + f"            {bias}\n"
            + "        }\n"
            + "    }\n"
            + "    }\n"
            + "}"
        )
    return (
        header
        + f"    for (size_t oc0 = 0; oc0 < {cout}; oc0 += oc_t) {{\n"
        + f"        {pack_call}\n"
        + f"        for (size_t oh0 = 0; oh0 < {oh}; oh0 += oh_t) {{\n"
        + f"        for (size_t ow0 = 0; ow0 < {ow}; ow0 += ow_t) {{\n"
        + f"            {im2col}\n"
        + "            const int32_t *stream_col_as = stream_col;\n"
        + gemm_inner
        + "\n"
        + f"            {bias}\n"
        + "        }\n"
        + "        }\n"
        + "    }\n"
        + "}"
    )


def emit_requant_i32(
    op: RuntimeOp,
    node: fx.Node,
    ctx: LoweringCtx,
    **_kwargs,
) -> str:
    src = node.args[0]
    if not isinstance(src, fx.Node):
        raise RegistryError("requant_i32 expects a tensor")
    mul = _as_int(node.args[1])
    shift = _as_int(node.args[2])
    shp = ctx.logical_shape(src)
    out = ctx.alloc(node.name, _node_meta_shape(node) or shp)
    n = numel(shp)
    call = f"{op.symbol}({ctx.cname(src)}, {out}, {n}, {mul}, {shift});"
    if ctx.stream:
        ctx.stream_need_stage = True
        return _stage_unary(
            f"{op.symbol}",
            ctx.cname(src),
            out,
            n,
        ).replace(
            f"{op.symbol}(stream_stage_a, stream_stage_b, m);",
            f"{op.symbol}(stream_stage_a, stream_stage_b, m, {mul}, {shift});",
        )
    return call


CODEGEN_HANDLERS = {
    "elementwise_binary": emit_elementwise_binary,
    "div_trunc": emit_div_trunc,
    "unary_same": emit_unary_same,
    "alias": emit_alias,
    "view": emit_view,
    "getitem": emit_getitem,
    "arange": emit_arange,
    "meshgrid": emit_meshgrid,
    "stack": emit_stack,
    "cat": emit_cat,
    "pad": emit_pad,
    "permute": emit_permute,
    "slice": emit_slice,
    "select": emit_select,
    "max_pool2d": emit_max_pool2d,
    "upsample_nearest": emit_upsample_nearest,
    "upsample_bilinear": emit_upsample_bilinear,
    "gemm_mmio": emit_gemm_mmio,
    "conv2d": emit_conv2d,
    "requant_i32": emit_requant_i32,
}
