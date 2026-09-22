# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Lower an FX graph to a host-testable C program that calls PyVedas runtime ops."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

import torch
import torch.fx as fx

from .codegen_handlers import CODEGEN_HANDLERS, DCCM_SLAB, LoweringCtx
from .memory import (
    BufferMaterializer,
    FlatRowMajorMaterializer,
    MemoryPlan,
    emit_static_buffers,
    format_shape,
)
from .memory.dram import DramImage
from .memory.materialize import DramMaterializer
from .registry import (
    RegistryError,
    RuntimeOp,
    _EXPORT_SKIP_TARGETS,
    canonical_graph_target,
    resolve_op,
)


@dataclass
class CompilePlan:
    memory: MemoryPlan
    statements: List[str]
    runtime_sources: List[Path]
    includes: List[str]
    result_names: List[str] = field(default_factory=list)
    input_names: List[str] = field(default_factory=list)
    result_goldens: List[Tuple[str, Tuple[int, ...]]] = field(default_factory=list)
    dram_image: DramImage | None = None
    checksum_goldens: bool = False
    stream_col_n: int = 0
    stream_col_cache_n: int = 0
    stream_wt_n: int = 0
    stream_acc_n: int = 0
    stream_gemm_n: int = 0
    stream_need_stage: bool = False
    stream_act_n: int = 0
    op_names: List[str] = field(default_factory=list)

    @property
    def result_name(self) -> str | None:
        return self.result_names[0] if self.result_names else None

    @property
    def result_golden(self) -> Tuple[int, ...]:
        if len(self.result_goldens) != 1:
            return ()
        return self.result_goldens[0][1]


def _buffer_name(node: fx.Node) -> str:
    return node.name.replace("%", "v_")


def _output_nodes(node: fx.Node) -> List[fx.Node]:
    value = node.args[0]
    if isinstance(value, (tuple, list)):
        nodes: List[fx.Node] = []
        for item in value:
            if not isinstance(item, fx.Node):
                raise RegistryError(f"Expected FX node in output, got {type(item)}")
            nodes.append(item)
        if not nodes:
            raise RegistryError(f"Empty graph output: {node.args}")
        return nodes
    if not isinstance(value, fx.Node):
        raise RegistryError(f"Expected FX node in output, got {type(value)}")
    return [value]


def _bind_trace_inputs(
    placeholders: List[fx.Node],
    trace_inputs: Tuple[Any, ...],
    materializer: BufferMaterializer,
) -> Tuple[MemoryPlan, Dict[str, str], Dict[str, Tuple[int, ...]]]:
    if len(placeholders) != len(trace_inputs):
        raise RegistryError(
            f"Expected {len(placeholders)} trace inputs, got {len(trace_inputs)}"
        )

    memory = MemoryPlan()
    buf: Dict[str, str] = {}
    shape: Dict[str, Tuple[int, ...]] = {}
    for node, trace_input in zip(placeholders, trace_inputs):
        cname = _buffer_name(node)
        buffer = materializer.materialize(cname, trace_input)
        memory.add(buffer)
        buf[node.name] = cname
        shape[node.name] = buffer.shape
    return memory, buf, shape


def _fetch_attr(root: Any, target: Any) -> Any:
    obj = root
    for part in str(target).split("."):
        obj = getattr(obj, part)
    return obj


def _last_use_index(graph: fx.Graph) -> Dict[str, int]:
    last: Dict[str, int] = {}
    for i, node in enumerate(graph.nodes):
        for inp in node.all_input_nodes:
            last[inp.name] = i
    return last


def _release_dead(
    ctx: LoweringCtx,
    node: fx.Node,
    last_use: Dict[str, int],
    idx: int,
    pinned: Set[str],
) -> None:
    if ctx.dram_image is None:
        return
    for inp in node.all_input_nodes:
        if last_use.get(inp.name) != idx:
            continue
        cname = ctx.buf.get(inp.name)
        if not cname or cname in pinned:
            continue
        shared_live = False
        for fxn, cn in ctx.buf.items():
            if cn == cname and last_use.get(fxn, -1) > idx:
                shared_live = True
                break
        if shared_live:
            continue
        buf = ctx.memory.buffers.get(cname)
        if buf is None or not buf.layout.is_dram:
            continue
        ctx.dram_image.free(
            buf.layout.offset, buf.layout.numel * buf.layout.elem_bytes
        )


def lower_graph(
    graph: fx.Graph,
    registry: Dict[str, RuntimeOp],
    trace_inputs: Tuple[Any, ...],
    *,
    materializer: BufferMaterializer | None = None,
    gemm_scratch_bytes: int | None = None,
    graph_module: fx.GraphModule | None = None,
    stream: bool = False,
    dram_image: DramImage | None = None,
) -> CompilePlan:
    materializer = materializer or FlatRowMajorMaterializer()

    placeholders = [n for n in graph.nodes if n.op == "placeholder"]
    memory, buf, shape = _bind_trace_inputs(placeholders, trace_inputs, materializer)
    last_use = _last_use_index(graph)
    pinned: Set[str] = set()

    ctx = LoweringCtx(
        memory=memory,
        buf=buf,
        shape=shape,
        tuples={},
        gemm_scratch_bytes=gemm_scratch_bytes,
        graph_module=graph_module,
        materializer=materializer,
        stream=stream,
        dram_image=dram_image,
    )

    statements: List[str] = []
    op_names: List[str] = []
    runtime_sources: List[Path] = []
    seen_sources: Set[Path] = set()
    result_names: List[str] = []
    input_names = [buf[n.name] for n in placeholders]
    pinned.update(input_names)

    for idx, node in enumerate(graph.nodes):
        if node.op == "placeholder":
            continue
        if node.op == "output":
            for src_node in _output_nodes(node):
                src = ctx.buf[src_node.name]
                src_buf = memory.get(src)
                result_names.append(src)
                statements.append(
                    f"/* result buffer: {src} shape={format_shape(src_buf.shape)} "
                    f"logical={format_shape(ctx.shape[src_node.name])} */"
                )
            continue
        if node.op == "call_module":
            continue
        if node.op == "get_attr":
            if graph_module is None:
                raise RegistryError(
                    f"get_attr '{node.target}' needs the GraphModule (node {node.name})"
                )
            tensor = _fetch_attr(graph_module, node.target)
            if not isinstance(tensor, torch.Tensor):
                raise RegistryError(
                    f"get_attr '{node.target}' is not a tensor (node {node.name})"
                )
            cname = _buffer_name(node)
            if isinstance(materializer, DramMaterializer):
                buffer = materializer.materialize_weight(cname, tensor)
            else:
                buffer = materializer.materialize(cname, tensor)
            memory.add(buffer)
            ctx.buf[node.name] = cname
            ctx.shape[node.name] = buffer.shape
            pinned.add(cname)
            continue
        if node.op != "call_function":
            raise RegistryError(f"Unsupported FX node type: {node.op} ({node.name})")

        if canonical_graph_target(node.target) in _EXPORT_SKIP_TARGETS:
            _release_dead(ctx, node, last_use, idx, pinned)
            continue

        op = resolve_op(registry, node.target)
        for src in op.sources:
            if src.path not in seen_sources:
                runtime_sources.append(src.path)
                seen_sources.add(src.path)

        handler = CODEGEN_HANDLERS.get(op.codegen)
        if handler is None:
            raise RegistryError(
                f"No codegen handler for '{op.graph_target}' "
                f"(codegen={op.codegen!r})"
            )

        statements.append(handler(op, node, ctx))
        op_names.append(f"{node.name}:{canonical_graph_target(node.target)}")
        _release_dead(ctx, node, last_use, idx, pinned)

    memcpy = pyvedas_root_memcpy()
    if stream and memcpy not in seen_sources:
        runtime_sources.append(memcpy)

    return CompilePlan(
        memory=memory,
        statements=statements,
        runtime_sources=runtime_sources,
        includes=["pyvedas.h"] + (["soc_defines.h"] if stream else []),
        result_names=result_names,
        input_names=input_names,
        dram_image=dram_image,
        stream_col_n=ctx.stream_col_n,
        stream_col_cache_n=ctx.stream_col_cache_n,
        stream_wt_n=ctx.stream_wt_n,
        stream_acc_n=ctx.stream_acc_n,
        stream_gemm_n=ctx.stream_gemm_n,
        stream_need_stage=ctx.stream_need_stage,
        stream_act_n=ctx.stream_act_n,
        op_names=op_names,
    )


def pyvedas_root_memcpy() -> Path:
    return Path(__file__).resolve().parents[1] / "runtime" / "c" / "pyvedas_memcpy.c"


def checksum_i32(values: Tuple[int, ...]) -> int:
    """Rotate-XOR checksum matching the generated target compare."""
    cs = 0
    for raw in values:
        cs ^= int(raw) & 0xFFFFFFFF
        cs = ((cs << 1) | (cs >> 31)) & 0xFFFFFFFF
    return cs


def _emit_stream_dccm(lines: List[str], plan: CompilePlan) -> None:
    """Layer kinds do not overlap: cache_col vs staged act+one col vs pool."""
    tile_n = int(plan.stream_col_n)
    cache_n = int(plan.stream_col_cache_n)
    act_n = int(plan.stream_act_n)
    stage_n = 2 * DCCM_SLAB if plan.stream_need_stage else 0
    staged_n = act_n + tile_n
    union_n = max(cache_n, staged_n, stage_n, act_n)
    if union_n:
        lines.append(
            "static int32_t stream_dccm["
            f"{union_n}] __attribute__((aligned(4)));"
        )
        if plan.stream_need_stage:
            lines.append("#define stream_stage_a (stream_dccm)")
            lines.append(f"#define stream_stage_b (stream_dccm + {DCCM_SLAB})")
        if act_n:
            lines.append("#define stream_act (stream_dccm)")
        if tile_n:
            lines.append(f"#define stream_col (stream_dccm + {act_n})")
        if cache_n:
            lines.append("#define stream_col_cache (stream_dccm)")
    elif act_n:
        lines.append(f"static int32_t stream_act[{act_n}];")
    if plan.stream_wt_n:
        lines.append(f"static int32_t stream_wt[{plan.stream_wt_n}];")
    if plan.stream_acc_n:
        lines.append(f"static int32_t stream_acc[{plan.stream_acc_n}];")
    if plan.stream_gemm_n:
        lines.append(
            f"static uint8_t stream_gemm_scratch[{plan.stream_gemm_n}] "
            "__attribute__((aligned(4)));"
        )


def emit_c(plan: CompilePlan, out_path: Path, *, target: bool = False) -> None:
    lines: List[str] = [
        "/* Generated by PyVedas JIT. */",
        "#include <stddef.h>",
        "#include <stdint.h>",
    ]
    for header in plan.includes:
        lines.append(f"#include <{header}>")
    if not target:
        lines.append("#include <stdio.h>")
    if target:
        lines.append("")
        lines.append("extern void eot_sequence(void);")

    lines.append("")
    lines.extend(emit_static_buffers(plan.memory))
    _emit_stream_dccm(lines, plan)
    if target:
        lines.append(
            "volatile uint32_t _pyvedas_op_limit "
            "__attribute__((section(\".data\"))) = 0xFFFFFFFFu;"
        )
        lines.append("static uint32_t _pyvedas_ops_done;")

    lines.append("")
    lines.append("int main(void) {")
    if target:
        # -nostdlib has no CRT, so GP is otherwise 0 and linker-relaxed
        # addi(gp, ...) misses .data/.bss (broadcast/bmm scratch, C, goldens).
        lines.append("    asm volatile (")
        lines.append('        ".option push\\n"')
        lines.append('        ".option norelax\\n"')
        lines.append('        "la gp, __global_pointer$\\n"')
        lines.append('        ".option pop"')
        lines.append('        :')
        lines.append('        :')
        lines.append('        : "gp"')
        lines.append("    );")
        lines.append("    _pyvedas_ops_done = 0;")
    op_i = 0
    for stmt in plan.statements:
        is_comment = all(
            (not ln.strip() or ln.strip().startswith("/*"))
            for ln in stmt.split("\n")
        )
        if target and not is_comment:
            name = (
                plan.op_names[op_i] if op_i < len(plan.op_names) else f"op{op_i + 1}"
            )
            op_i += 1
            lines.append(f"    /* op {op_i}: {name} */")
            lines.append("    {")
            for line in stmt.split("\n"):
                lines.append(f"        {line}" if line else "")
            lines.append("    }")
            lines.append("    _pyvedas_ops_done++;")
            lines.append(
                "    if (_pyvedas_ops_done >= _pyvedas_op_limit) "
                "goto _pyvedas_eot;"
            )
        else:
            for line in stmt.split("\n"):
                lines.append(f"    {line}" if line else "")

    if target:
        if plan.checksum_goldens:
            for out_name, vals in plan.result_goldens:
                info = plan.memory.get(out_name)
                cs = checksum_i32(vals)
                lines.append("    {")
                lines.append("        uint32_t _cs = 0;")
                lines.append(f"        for (size_t i = 0; i < {info.numel}; i++) {{")
                lines.append(f"            _cs ^= (uint32_t){out_name}[i];")
                lines.append("            _cs = (_cs << 1) | (_cs >> 31);")
                lines.append("        }")
                lines.append(f"        if (_cs != {cs}u) {{")
                lines.append("            for (;;);")
                lines.append("        }")
                lines.append("    }")
        else:
            for out_name, vals in plan.result_goldens:
                info = plan.memory.get(out_name)
                joined = ", ".join(str(v) for v in vals)
                lines.append(
                    f"    static const {info.c_type} _eot_golden_{out_name}"
                    f"[{info.numel}] = {{ {joined} }};"
                )
                lines.append(f"    for (size_t i = 0; i < {info.numel}; i++) {{")
                lines.append(
                    f"        if ({out_name}[i] != _eot_golden_{out_name}[i]) {{"
                )
                lines.append("            for (;;);")
                lines.append("        }")
                lines.append("    }")
        lines.append("_pyvedas_eot:")
        lines.append("    eot_sequence();")
    else:
        output_names = list(plan.result_names)
        if not output_names:
            output_names = [
                b.name for b in plan.memory.buffers.values() if not b.is_initialized
            ]
        for out_name in output_names:
            info = plan.memory.get(out_name)
            lines.append(f"    for (size_t i = 0; i < {info.numel}; i++) {{")
            lines.append(
                f'        printf("{out_name}[%zu]=%d\\n", i, (int){out_name}[i]);'
            )
            lines.append("    }")

    lines.append("    return 0;")
    lines.append("}")
    lines.append("")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
