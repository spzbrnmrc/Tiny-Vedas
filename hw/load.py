# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Load and validate hardware configuration presets."""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

import yaml

from .types import (
    CpuConfig,
    CpuKind,
    HwConfig,
    MemoryConfig,
    SoftwareHints,
    VectorUnitConfig,
)

_REPO_ROOT = Path(__file__).resolve().parents[1]
PRESETS_DIR = _REPO_ROOT / "hw" / "presets"
DEFAULT_PRESET = PRESETS_DIR / "rv32im_scalar.yaml"

_VALID_CPU_KINDS = {kind.value for kind in CpuKind}


class HwConfigError(ValueError):
    pass


def repo_root() -> Path:
    return _REPO_ROOT


def default_hw_config_path() -> Path:
    return DEFAULT_PRESET


def list_presets() -> Iterable[Path]:
    return sorted(PRESETS_DIR.glob("*.yaml"))


def _require(mapping: dict, key: str, ctx: str) -> Any:
    if key not in mapping:
        raise HwConfigError(f"Missing '{key}' in {ctx}")
    return mapping[key]


def load_hw_config(path: Path | str | None = None) -> HwConfig:
    """Load a hardware config YAML file into a typed :class:`HwConfig`."""
    config_path = Path(path).resolve() if path else DEFAULT_PRESET.resolve()
    if not config_path.exists():
        raise HwConfigError(f"Hardware config not found: {config_path}")

    with open(config_path, "r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    cpu_raw = _require(raw, "cpu", config_path.name)
    vector_raw = _require(raw, "vector", config_path.name)
    memory_raw = _require(raw, "memory", config_path.name)
    software_raw = _require(raw, "software", config_path.name)

    cpu_kind = str(_require(cpu_raw, "kind", "cpu"))
    if cpu_kind not in _VALID_CPU_KINDS:
        raise HwConfigError(
            f"Unsupported cpu.kind '{cpu_kind}' in {config_path.name}; "
            f"expected one of {sorted(_VALID_CPU_KINDS)}"
        )

    return HwConfig(
        name=str(_require(raw, "name", config_path.name)),
        version=int(_require(raw, "version", config_path.name)),
        description=str(raw.get("description", "")),
        source_path=str(config_path),
        cpu=CpuConfig(
            kind=CpuKind(cpu_kind),
            isa=str(_require(cpu_raw, "isa", "cpu")),
            issue_width=int(_require(cpu_raw, "issue_width", "cpu")),
            commit_width=int(_require(cpu_raw, "commit_width", "cpu")),
            pipeline_stages=int(_require(cpu_raw, "pipeline_stages", "cpu")),
            out_of_order=bool(_require(cpu_raw, "out_of_order", "cpu")),
        ),
        vector=VectorUnitConfig(
            enabled=bool(_require(vector_raw, "enabled", "vector")),
            width_bits=int(_require(vector_raw, "width_bits", "vector")),
            lanes=int(_require(vector_raw, "lanes", "vector")),
            local_mem_bytes=int(_require(vector_raw, "local_mem_bytes", "vector")),
        ),
        memory=MemoryConfig(
            iccm_depth_words=int(_require(memory_raw, "iccm_depth_words", "memory")),
            dccm_depth_words=int(_require(memory_raw, "dccm_depth_words", "memory")),
            link_address=int(_require(memory_raw, "link_address", "memory")),
            uart_address=int(_require(memory_raw, "uart_address", "memory")),
            eot_address=int(_require(memory_raw, "eot_address", "memory")),
        ),
        software=SoftwareHints(
            materializer=str(_require(software_raw, "materializer", "software")),
            vectorize_min_numel=int(
                _require(software_raw, "vectorize_min_numel", "software")
            ),
        ),
    )
