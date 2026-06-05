"""Bridge Tiny-Vedas hardware presets into PyVedas compilation."""

from __future__ import annotations

import sys
from pathlib import Path

from .memory import BufferMaterializer, FlatRowMajorMaterializer

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from hw import HwConfig, default_hw_config_path, load_hw_config  # noqa: E402


def resolve_hw_config(path: Path | str | None) -> HwConfig:
    if path is None:
        return load_hw_config(default_hw_config_path())
    return load_hw_config(path)


def select_materializer(hw: HwConfig) -> BufferMaterializer:
    """Pick a buffer materialization strategy for *hw*.

    Only ``flat_row_major`` is implemented today. Future strategies
    (``tiled_vliw``, ``vector_local_mem``, …) plug in here.
    """
    kind = hw.software.materializer
    if kind == "flat_row_major":
        return FlatRowMajorMaterializer()
    raise ValueError(
        f"Unsupported software.materializer '{kind}' for preset '{hw.name}'"
    )


__all__ = ["HwConfig", "resolve_hw_config", "select_materializer"]
