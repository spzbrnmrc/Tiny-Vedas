# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Compile-time memory types for PyVedas buffer planning.

Logical tensors from the GraphModule are lowered to StaticBuffer objects.
Physical placement (DCCM regions, tiling, strides) is decided here and
emitted later — this module is the primary extension point for SoC-aware
memory optimizations.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Tuple


@dataclass(frozen=True)
class ElementType:
    """C type used for one scalar element in generated code."""

    c_type: str
    size_bytes: int


@dataclass(frozen=True)
class BufferLayout:
    """Physical view of a logical buffer.

    ``flat_row_major`` is a DCCM ``static`` array. ``dram_buffer`` is a
    pointer into the AXI DRAM stub (``DRAM_BASE + offset``).
    """

    kind: str
    numel: int
    offset: int = 0
    elem_bytes: int = 4

    @staticmethod
    def flat_row_major(numel: int) -> BufferLayout:
        return BufferLayout(kind="flat_row_major", numel=numel)

    @staticmethod
    def dram_buffer(numel: int, offset: int, elem_bytes: int = 4) -> BufferLayout:
        return BufferLayout(
            kind="dram_buffer", numel=numel, offset=offset, elem_bytes=elem_bytes
        )

    @property
    def is_dram(self) -> bool:
        return self.kind == "dram_buffer"


@dataclass
class StaticBuffer:
    """A compile-time buffer: metadata + optional baked-in trace values."""

    name: str
    shape: Tuple[int, ...]
    element: ElementType
    layout: BufferLayout
    values: Tuple[int, ...] = field(default_factory=tuple)

    @property
    def numel(self) -> int:
        return self.layout.numel

    @property
    def c_type(self) -> str:
        return self.element.c_type

    @property
    def is_initialized(self) -> bool:
        return bool(self.values)


@dataclass
class MemoryPlan:
    """Owns all static buffers for one compiled model."""

    buffers: Dict[str, StaticBuffer] = field(default_factory=dict)

    def add(self, buffer: StaticBuffer) -> StaticBuffer:
        if buffer.name in self.buffers:
            raise ValueError(f"Duplicate buffer name: {buffer.name}")
        self.buffers[buffer.name] = buffer
        return buffer

    def get(self, name: str) -> StaticBuffer:
        try:
            return self.buffers[name]
        except KeyError as exc:
            raise KeyError(f"Unknown buffer: {name}") from exc

    def allocate_uninitialized(self, name: str, template: StaticBuffer) -> StaticBuffer:
        """Reserve an output buffer with the same shape/type/layout as *template*."""
        return self.add(
            StaticBuffer(
                name=name,
                shape=template.shape,
                element=template.element,
                layout=template.layout,
                values=tuple(),
            )
        )

    def allocate_shape(
        self,
        name: str,
        shape: Tuple[int, ...],
        *,
        c_type: str = "int32_t",
        size_bytes: int = 4,
    ) -> StaticBuffer:
        numel = 1
        for dim in shape:
            numel *= int(dim)
        return self.add(
            StaticBuffer(
                name=name,
                shape=tuple(int(d) for d in shape),
                element=ElementType(c_type=c_type, size_bytes=size_bytes),
                layout=BufferLayout.flat_row_major(numel),
            )
        )
