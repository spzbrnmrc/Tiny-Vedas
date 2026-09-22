# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""Load and validate hardware configuration presets."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Iterable

import yaml

from .types import (
    CpuConfig,
    CpuKind,
    ExuUnitMask,
    HwConfig,
    MemoryConfig,
    MmioDevice,
    SocConfig,
    SoftwareHints,
    VectorUnitConfig,
)

_REPO_ROOT = Path(__file__).resolve().parents[1]
PRESETS_DIR = _REPO_ROOT / "hw" / "presets"
SOC_DIR = _REPO_ROOT / "hw" / "soc"
DEFAULT_PRESET = PRESETS_DIR / "rv32im_zve32x.yaml"
DEFAULT_SOC = SOC_DIR / "default.yaml"

_VALID_CPU_KINDS = {kind.value for kind in CpuKind}
_VALID_ACCESS = {"read", "write"}
_VALID_ROLES = {"uart", "eot", "mmio", "accelerator"}
_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
_MACRO_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class HwConfigError(ValueError):
    pass


def repo_root() -> Path:
    return _REPO_ROOT


def default_hw_config_path() -> Path:
    return DEFAULT_PRESET


def default_soc_config_path() -> Path:
    return DEFAULT_SOC


def list_presets() -> Iterable[Path]:
    return sorted(PRESETS_DIR.glob("*.yaml"))


def list_soc_maps() -> Iterable[Path]:
    return sorted(SOC_DIR.glob("*.yaml"))


def _require(mapping: dict, key: str, ctx: str) -> Any:
    if key not in mapping:
        raise HwConfigError(f"Missing '{key}' in {ctx}")
    return mapping[key]


def _parse_int(value: Any, ctx: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise HwConfigError(f"{ctx} must be an integer (got {value!r})")
    return int(value)


def _parse_exu_units(cpu_raw: dict, issue_width: int, ctx: str) -> tuple[ExuUnitMask, ...]:
    if "exu" not in cpu_raw:
        return tuple(ExuUnitMask.all_enabled() for _ in range(issue_width))

    exu_raw = cpu_raw["exu"]
    if not isinstance(exu_raw, list):
        raise HwConfigError(f"cpu.exu must be a list in {ctx}")

    if len(exu_raw) != issue_width:
        raise HwConfigError(
            f"cpu.exu length ({len(exu_raw)}) must match cpu.issue_width "
            f"({issue_width}) in {ctx}"
        )

    units: list[ExuUnitMask] = []
    for idx, entry in enumerate(exu_raw):
        if not isinstance(entry, dict):
            raise HwConfigError(f"cpu.exu[{idx}] must be a mapping in {ctx}")
        units.append(
            ExuUnitMask(
                alu=bool(entry.get("alu", True)),
                mul=bool(entry.get("mul", True)),
                div=bool(entry.get("div", True)),
                lsu=bool(entry.get("lsu", True)),
            )
        )
    return tuple(units)


def resolve_soc_path(ref: str | Path | None, hw_path: Path | None = None) -> Path:
    """Resolve a SoC map name or path to an absolute YAML path."""
    if ref is None:
        return DEFAULT_SOC.resolve()

    raw = str(ref)
    path = Path(raw)
    if path.suffix in {".yaml", ".yml"}:
        if not path.is_absolute():
            candidates = []
            if hw_path is not None:
                candidates.append((hw_path.parent / path).resolve())
            candidates.append((_REPO_ROOT / path).resolve())
            for cand in candidates:
                if cand.exists():
                    return cand
            return candidates[0]
        return path.resolve()
    return (SOC_DIR / f"{raw}.yaml").resolve()


def _parse_device(raw: dict, index: int, ctx: str) -> MmioDevice:
    dctx = f"{ctx} devices[{index}]"
    if not isinstance(raw, dict):
        raise HwConfigError(f"{dctx} must be a mapping")

    name = str(_require(raw, "name", dctx))
    if not _NAME_RE.match(name):
        raise HwConfigError(f"{dctx}: invalid device name '{name}'")

    role = str(raw.get("role", "mmio"))
    if role not in _VALID_ROLES:
        raise HwConfigError(
            f"{dctx}: unsupported role '{role}'; expected one of {sorted(_VALID_ROLES)}"
        )

    base = _parse_int(_require(raw, "base", dctx), f"{dctx}.base")
    size = _parse_int(_require(raw, "size", dctx), f"{dctx}.size")
    if base < 0 or base > 0xFFFFFFFF:
        raise HwConfigError(f"{dctx}.base out of 32-bit range")
    if size <= 0 or size > 0x100000000:
        raise HwConfigError(f"{dctx}.size must be > 0")
    if base + size > 0x100000000:
        raise HwConfigError(f"{dctx}: base+size overflows 32-bit space")

    access_raw = raw.get("access", ["write"])
    if isinstance(access_raw, str):
        access_raw = [access_raw]
    if not isinstance(access_raw, list) or not access_raw:
        raise HwConfigError(f"{dctx}.access must be a non-empty list")
    access = tuple(str(a) for a in access_raw)
    unknown = set(access) - _VALID_ACCESS
    if unknown:
        raise HwConfigError(f"{dctx}.access has unsupported values {sorted(unknown)}")

    module = raw.get("module")
    module_s = None if module in (None, "") else str(module)

    params_raw = raw.get("params") or {}
    if not isinstance(params_raw, dict):
        raise HwConfigError(f"{dctx}.params must be a mapping")

    sw_raw = raw.get("sw") or {}
    if not isinstance(sw_raw, dict):
        raise HwConfigError(f"{dctx}.sw must be a mapping")

    addr_macro = str(sw_raw.get("addr_macro", f"MMIO_{name.upper()}_ADDR"))
    size_macro = str(sw_raw.get("size_macro", f"MMIO_{name.upper()}_SIZE"))
    magic_macro_raw = sw_raw.get("magic_macro")
    magic_macro = None if magic_macro_raw in (None, "") else str(magic_macro_raw)

    for label, macro in (("addr_macro", addr_macro), ("size_macro", size_macro)):
        if not _MACRO_RE.match(macro):
            raise HwConfigError(f"{dctx}.sw.{label} is not a valid identifier: '{macro}'")
    if magic_macro is not None and not _MACRO_RE.match(magic_macro):
        raise HwConfigError(f"{dctx}.sw.magic_macro is not a valid identifier: '{magic_macro}'")

    if role == "eot":
        if "magic" not in params_raw:
            raise HwConfigError(f"{dctx}: eot device requires params.magic")
        _parse_int(params_raw["magic"], f"{dctx}.params.magic")
        if magic_macro is None:
            magic_macro = "EOT_MAGIC"

    return MmioDevice(
        name=name,
        compatible=str(raw.get("compatible", f"tv,{name}")),
        role=role,
        base=base,
        size=size,
        access=access,
        module=module_s,
        params=dict(params_raw),
        addr_macro=addr_macro,
        size_macro=size_macro,
        magic_macro=magic_macro,
    )


def _validate_devices(devices: tuple[MmioDevice, ...], ctx: str) -> None:
    if not devices:
        raise HwConfigError(f"{ctx}: devices list is empty")

    names = [d.name for d in devices]
    if len(names) != len(set(names)):
        raise HwConfigError(f"{ctx}: duplicate device names")

    macros = [d.addr_macro for d in devices] + [d.size_macro for d in devices]
    macros += [d.magic_macro for d in devices if d.magic_macro]
    if len(macros) != len(set(macros)):
        raise HwConfigError(f"{ctx}: duplicate software macro names")

    ordered = sorted(devices, key=lambda d: d.base)
    for prev, cur in zip(ordered, ordered[1:]):
        if cur.base < prev.end:
            raise HwConfigError(
                f"{ctx}: device '{cur.name}' [0x{cur.base:08x}, 0x{cur.end:08x}) "
                f"overlaps '{prev.name}' [0x{prev.base:08x}, 0x{prev.end:08x})"
            )

    for role in ("uart", "eot"):
        hits = [d for d in devices if d.role == role]
        if len(hits) != 1:
            raise HwConfigError(
                f"{ctx}: need exactly one device with role '{role}' (found {len(hits)})"
            )


def load_soc_config(path: Path | str | None = None) -> SocConfig:
    """Load a SoC device-map YAML into a typed :class:`SocConfig`."""
    config_path = Path(path).resolve() if path else DEFAULT_SOC.resolve()
    if not config_path.exists():
        raise HwConfigError(f"SoC config not found: {config_path}")

    with open(config_path, "r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    devices_raw = _require(raw, "devices", config_path.name)
    if not isinstance(devices_raw, list):
        raise HwConfigError(f"{config_path.name}: devices must be a list")

    devices = tuple(
        _parse_device(entry, idx, config_path.name)
        for idx, entry in enumerate(devices_raw)
    )
    _validate_devices(devices, config_path.name)

    return SocConfig(
        name=str(_require(raw, "name", config_path.name)),
        version=int(_require(raw, "version", config_path.name)),
        description=str(raw.get("description", "")),
        source_path=str(config_path),
        devices=devices,
    )


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

    issue_width = int(_require(cpu_raw, "issue_width", "cpu"))

    soc_ref = raw.get("soc", "default")
    soc = load_soc_config(resolve_soc_path(soc_ref, config_path))
    uart = soc.require_role("uart")
    eot = soc.require_role("eot")
    eot_magic = int(eot.params["magic"]) & 0xFFFFFFFF

    vec_enabled = bool(_require(vector_raw, "enabled", "vector"))
    vec_width = int(_require(vector_raw, "width_bits", "vector"))
    vec_dlen = int(vector_raw.get("dlen_bits", 0))
    vec_lanes = int(_require(vector_raw, "lanes", "vector"))
    if vec_enabled:
        if vec_width <= 0 or vec_dlen <= 0 or vec_lanes <= 0:
            raise HwConfigError(
                f"{config_path.name}: vector.enabled requires width_bits, "
                f"dlen_bits, and lanes > 0"
            )
        if vec_width % vec_dlen != 0:
            raise HwConfigError(
                f"{config_path.name}: vector.width_bits must be a multiple of "
                f"vector.dlen_bits"
            )

    return HwConfig(
        name=str(_require(raw, "name", config_path.name)),
        version=int(_require(raw, "version", config_path.name)),
        description=str(raw.get("description", "")),
        source_path=str(config_path),
        cpu=CpuConfig(
            kind=CpuKind(cpu_kind),
            isa=str(_require(cpu_raw, "isa", "cpu")),
            issue_width=issue_width,
            out_of_order=bool(_require(cpu_raw, "out_of_order", "cpu")),
            exu=_parse_exu_units(cpu_raw, issue_width, config_path.name),
        ),
        vector=VectorUnitConfig(
            enabled=vec_enabled,
            width_bits=vec_width,
            dlen_bits=vec_dlen,
            lanes=vec_lanes,
            local_mem_bytes=int(_require(vector_raw, "local_mem_bytes", "vector")),
        ),
        memory=MemoryConfig(
            iccm_depth_words=int(_require(memory_raw, "iccm_depth_words", "memory")),
            dccm_depth_words=int(_require(memory_raw, "dccm_depth_words", "memory")),
            link_address=int(_require(memory_raw, "link_address", "memory")),
            uart_address=uart.base,
            eot_address=eot.base,
            eot_magic=eot_magic,
            dram_base=int(memory_raw.get("dram_base", 0x40000000)),
            dram_bytes=int(memory_raw.get("dram_bytes", 16 * 1024 * 1024)),
        ),
        software=SoftwareHints(
            materializer=str(_require(software_raw, "materializer", "software")),
            vectorize_min_numel=int(
                _require(software_raw, "vectorize_min_numel", "software")
            ),
        ),
        soc=soc,
    )
