# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Lower an FX graph to a host-testable C program that calls PyVedas runtime ops."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

import torch
import torch.fx as fx

from .codegen_handlers import CODEGEN_HANDLERS, LoweringCtx
from .memory import (
    BufferMaterializer,
    FlatRowMajorMaterializer,
    MemoryPlan,
    emit_static_buffers,
    format_shape,
)
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
    result_goldens: List[Tuple[str, Tuple[int, ...]]] = field(default_factory=list)

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


def lower_graph(
    graph: fx.Graph,
    registry: Dict[str, RuntimeOp],
    trace_inputs: Tuple[Any, ...],
    *,
    materializer: BufferMaterializer | None = None,
    gemm_scratch_bytes: int | None = None,
    graph_module: fx.GraphModule | None = None,
) -> CompilePlan:
    materializer = materializer or FlatRowMajorMaterializer()

    placeholders = [n for n in graph.nodes if n.op == "placeholder"]
    memory, buf, shape = _bind_trace_inputs(placeholders, trace_inputs, materializer)

    ctx = LoweringCtx(
        memory=memory,
        buf=buf,
        shape=shape,
        tuples={},
        gemm_scratch_bytes=gemm_scratch_bytes,
        graph_module=graph_module,
        materializer=materializer,
    )

    statements: List[str] = []
    runtime_sources: List[Path] = []
    seen_sources: Set[Path] = set()
    result_names: List[str] = []

    for node in graph.nodes:
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
            buffer = materializer.materialize(cname, tensor)
            memory.add(buffer)
            ctx.buf[node.name] = cname
            ctx.shape[node.name] = buffer.shape
            continue
        if node.op != "call_function":
            raise RegistryError(f"Unsupported FX node type: {node.op} ({node.name})")

        if canonical_graph_target(node.target) in _EXPORT_SKIP_TARGETS:
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

    return CompilePlan(
        memory=memory,
        statements=statements,
        runtime_sources=runtime_sources,
        includes=["pyvedas.h"],
        result_names=result_names,
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
    for stmt in plan.statements:
        for line in stmt.split("\n"):
            lines.append(f"    {line}" if line else "")

    if target:
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
