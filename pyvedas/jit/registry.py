"""Discover PyVedas runtime ops and resolve graph nodes to implementations."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, List

import yaml


@dataclass(frozen=True)
class SourceArtifact:
    kind: str  # c | asm | elf
    path: Path


@dataclass(frozen=True)
class RuntimeOp:
    graph_target: str
    symbol: str
    signature: str
    codegen: str
    sources: tuple[SourceArtifact, ...]


class RegistryError(RuntimeError):
    pass


def canonical_graph_target(target: Any) -> str:
    """Normalize FX node targets to ops.yaml keys (e.g. aten.add.Tensor)."""
    if isinstance(target, str):
        return target
    as_str = str(target)
    if as_str.startswith("aten.") or as_str.startswith("operator."):
        return as_str
    name = getattr(target, "__name__", None)
    if name:
        return name
    return repr(target)


def load_registry(pyvedas_root: Path) -> dict[str, RuntimeOp]:
    """Load the 1:1 GraphModule-op -> implementation map."""
    manifest = pyvedas_root / "runtime" / "ops.yaml"
    if not manifest.exists():
        raise RegistryError(f"Missing runtime manifest: {manifest}")

    with open(manifest, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    by_target: dict[str, RuntimeOp] = {}
    for graph_target, spec in data.get("ops", {}).items():
        if graph_target in by_target:
            raise RegistryError(
                f"Duplicate GraphModule op in ops.yaml: '{graph_target}'"
            )

        sources: List[SourceArtifact] = []
        for entry in spec.get("sources", []):
            rel = Path(entry["path"])
            src_path = pyvedas_root / rel
            if not src_path.exists():
                raise RegistryError(
                    f"Op '{graph_target}' source not found: {src_path}"
                )
            sources.append(SourceArtifact(kind=entry["kind"], path=src_path))

        op = RuntimeOp(
            graph_target=graph_target,
            symbol=spec["symbol"],
            signature=spec["signature"],
            codegen=spec.get("codegen", ""),
            sources=tuple(sources),
        )
        by_target[graph_target] = op

    return by_target


def resolve_op(registry: dict[str, RuntimeOp], target: Any) -> RuntimeOp:
    """Resolve an FX node target to its single registered implementation."""
    key = canonical_graph_target(target)
    if key in registry:
        return registry[key]

    raise RegistryError(
        f"No 1:1 PyVedas implementation for GraphModule op '{key}'. "
        f"Add '{key}' to runtime/ops.yaml with a matching source file."
    )


def validate_graph_ops(graph, registry: dict[str, RuntimeOp]) -> None:
    """Ensure every compute op in the graph has exactly one implementation."""
    missing: List[str] = []
    for node in graph.nodes:
        if node.op != "call_function":
            continue
        try:
            resolve_op(registry, node.target)
        except RegistryError:
            missing.append(canonical_graph_target(node.target))

    if missing:
        listed = ", ".join(sorted(set(missing)))
        raise RegistryError(
            f"Graph contains ops with no 1:1 implementation: {listed}"
        )
