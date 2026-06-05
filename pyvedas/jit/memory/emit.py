# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Emit C declarations from a :class:`MemoryPlan`."""

from __future__ import annotations

from typing import List

from .types import MemoryPlan, StaticBuffer


def format_shape(shape: tuple[int, ...]) -> str:
    return "x".join(str(dim) for dim in shape)


def buffer_header_comment(buffer: StaticBuffer) -> str:
    return (
        f"/* shape: {format_shape(buffer.shape)} "
        f"layout={buffer.layout.kind} numel={buffer.numel} */"
    )


def emit_static_declaration(buffer: StaticBuffer) -> List[str]:
    lines = [buffer_header_comment(buffer)]
    if buffer.is_initialized:
        vals = ", ".join(str(v) for v in buffer.values)
        lines.append(
            f"static {buffer.c_type} {buffer.name}[{buffer.numel}] = {{ {vals} }};"
        )
    else:
        lines.append(f"static {buffer.c_type} {buffer.name}[{buffer.numel}];")
    return lines


def emit_static_buffers(plan: MemoryPlan) -> List[str]:
    lines: List[str] = []
    for buffer in plan.buffers.values():
        lines.extend(emit_static_declaration(buffer))
    return lines
