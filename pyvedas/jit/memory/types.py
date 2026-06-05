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

    Today every buffer is a flat row-major vector (``flat_row_major``).
    Future layout kinds may include tiled views, explicit DCCM sections, or
    strided windows — without changing runtime op signatures (ptr + numel).
    """

    kind: str
    numel: int

    @staticmethod
    def flat_row_major(numel: int) -> BufferLayout:
        return BufferLayout(kind="flat_row_major", numel=numel)


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
