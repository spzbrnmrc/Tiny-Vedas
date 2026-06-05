"""Typed hardware configuration for Tiny-Vedas CPU flavors."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Dict


class CpuKind(str, Enum):
    SCALAR = "scalar"
    VLIW = "vliw"
    SUPERSCALAR = "superscalar"
    OOO = "ooo"


@dataclass(frozen=True)
class CpuConfig:
    kind: CpuKind
    isa: str
    issue_width: int
    commit_width: int
    pipeline_stages: int
    out_of_order: bool


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

    @property
    def has_vector_unit(self) -> bool:
        return self.vector.enabled and self.vector.lanes > 0

    def to_dict(self) -> Dict[str, Any]:
        def _convert(obj: Any) -> Any:
            if isinstance(obj, Enum):
                return obj.value
            if hasattr(obj, "__dataclass_fields__"):
                return {k: _convert(v) for k, v in asdict(obj).items()}
            return obj

        return _convert(self)
