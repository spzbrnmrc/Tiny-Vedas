# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Graph op → C statement handlers.

Each handler reads/writes a :class:`MemoryPlan` and returns one statement.
Register new handlers in ``CODEGEN_HANDLERS`` keyed by ``RuntimeOp.codegen``.
"""

from __future__ import annotations

import torch.fx as fx

from .memory import MemoryPlan, StaticBuffer, format_shape
from .registry import RegistryError, RuntimeOp


def _buffer_name(node: fx.Node) -> str:
    return node.name.replace("%", "v_")


def emit_elementwise_binary(
    op: RuntimeOp,
    node: fx.Node,
    memory: MemoryPlan,
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


CODEGEN_HANDLERS = {
    "elementwise_binary": emit_elementwise_binary,
}
