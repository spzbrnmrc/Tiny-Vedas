# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Typed hardware configuration for Tiny-Vedas CPU flavors."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Dict, Optional, Tuple


class CpuKind(str, Enum):
    SCALAR = "scalar"
    VLIW = "vliw"
    SUPERSCALAR = "superscalar"
    OOO = "ooo"


@dataclass(frozen=True)
class ExuUnitMask:
    """Functional units enabled in one EXU instance."""

    alu: bool
    mul: bool
    div: bool
    lsu: bool

    @staticmethod
    def all_enabled() -> ExuUnitMask:
        return ExuUnitMask(alu=True, mul=True, div=True, lsu=True)


@dataclass(frozen=True)
class CpuConfig:
    kind: CpuKind
    isa: str
    issue_width: int
    out_of_order: bool
    exu: Tuple[ExuUnitMask, ...]


@dataclass(frozen=True)
class VectorUnitConfig:
    enabled: bool
    width_bits: int
    lanes: int
    local_mem_bytes: int


@dataclass(frozen=True)
class MemoryConfig:
    iccm_depth_words: int
    dccm_depth_words: int
    link_address: int
    uart_address: int
    eot_address: int
    eot_magic: int


@dataclass(frozen=True)
class MmioDevice:
    """One MMIO region on the SoC device mux."""

    name: str
    compatible: str
    role: str
    base: int
    size: int
    access: Tuple[str, ...]
    module: Optional[str]
    params: Dict[str, Any]
    addr_macro: str
    size_macro: str
    magic_macro: Optional[str]

    @property
    def end(self) -> int:
        return self.base + self.size

    def contains(self, addr: int) -> bool:
        return self.base <= (addr & 0xFFFFFFFF) < self.end


@dataclass(frozen=True)
class SocConfig:
    """Board/SoC device tree: MMIO map used to generate the mux and SW headers."""

    name: str
    version: int
    description: str
    source_path: str
    devices: Tuple[MmioDevice, ...]

    def device_by_name(self, name: str) -> MmioDevice:
        for dev in self.devices:
            if dev.name == name:
                return dev
        raise KeyError(f"No SoC device named '{name}'")

    def devices_by_role(self, role: str) -> Tuple[MmioDevice, ...]:
        return tuple(d for d in self.devices if d.role == role)

    def require_role(self, role: str) -> MmioDevice:
        hits = self.devices_by_role(role)
        if len(hits) != 1:
            raise KeyError(
                f"SoC map '{self.name}' must contain exactly one device with "
                f"role '{role}' (found {len(hits)})"
            )
        return hits[0]


@dataclass(frozen=True)
class SoftwareHints:
    """SW-side knobs (PyVedas materialization, vectorization thresholds)."""

    materializer: str
    vectorize_min_numel: int


@dataclass(frozen=True)
class HwConfig:
    """Resolved hardware description shared by RTL, sim_manager, and PyVedas."""

    name: str
    version: int
    description: str
    source_path: str
    cpu: CpuConfig
    vector: VectorUnitConfig
    memory: MemoryConfig
    software: SoftwareHints
    soc: SocConfig

    @property
    def has_vector_unit(self) -> bool:
        return self.vector.enabled and self.vector.lanes > 0

    def to_dict(self) -> Dict[str, Any]:
        def _convert(obj: Any) -> Any:
            if isinstance(obj, Enum):
                return obj.value
            if hasattr(obj, "__dataclass_fields__"):
                return {k: _convert(v) for k, v in asdict(obj).items()}
            if isinstance(obj, tuple):
                return [_convert(v) for v in obj]
            return obj

        return _convert(self)
