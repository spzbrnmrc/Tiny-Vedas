"""Trace-input → StaticBuffer materialization strategies.

``FlatRowMajorMaterializer`` is the default strategy. Replace or compose
materializers here when adding tiling, padding, or SoC-specific layouts.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Tuple

import torch

from ..registry import RegistryError
from .types import BufferLayout, ElementType, StaticBuffer


def resolve_element_type(tensor: torch.Tensor) -> ElementType:
    if tensor.dtype in (torch.int32, torch.int64):
        return ElementType(c_type="int32_t", size_bytes=4)
    if tensor.dtype in (torch.float32, torch.float64):
        raise RegistryError(
            "Float trace inputs are not supported for Tiny-Vedas targets yet "
            "(no soft-float runtime in the bare-metal toolchain). "
            "Use torch.int32 trace inputs."
        )
    raise RegistryError(f"Unsupported trace input dtype: {tensor.dtype}")


def flatten_row_major(tensor: torch.Tensor, element: ElementType) -> Tuple[int, ...]:
    """Collapse a trace tensor to a 1-D value sequence (row-major)."""
    if element.c_type == "int32_t":
        data = tensor.to(torch.int32).reshape(-1)
        return tuple(int(x) for x in data.tolist())
    raise RegistryError(f"No flatten rule for element type {element.c_type}")


class BufferMaterializer(ABC):
    """Strategy that turns a trace tensor into a ``StaticBuffer``."""

    @abstractmethod
    def materialize(self, name: str, tensor: torch.Tensor) -> StaticBuffer:
        raise NotImplementedError


class FlatRowMajorMaterializer(BufferMaterializer):
    """Default: contiguous row-major flatten into a single static vector."""

    def materialize(self, name: str, tensor: torch.Tensor) -> StaticBuffer:
        tensor = tensor.detach().contiguous()
        shape = tuple(int(dim) for dim in tensor.shape)
        element = resolve_element_type(tensor)
        values = flatten_row_major(tensor, element)
        numel = len(values)

        return StaticBuffer(
            name=name,
            shape=shape,
            element=element,
            layout=BufferLayout.flat_row_major(numel),
            values=values,
        )
