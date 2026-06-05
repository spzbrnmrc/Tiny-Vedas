"""Import a torch.compile / torch.export compatible FX graph from a PyTorch module."""

from __future__ import annotations

import contextlib
import io
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List, Tuple

import torch
import torch.fx as fx


@dataclass(frozen=True)
class ImportedGraph:
    graph: fx.Graph
    graph_module: fx.GraphModule
    backend: str


def _unwrap_compiled(model: torch.nn.Module) -> torch.nn.Module:
    """``torch.compile`` wraps the original module; export needs the inner graph."""
    orig = getattr(model, "_orig_mod", None)
    return orig if orig is not None else model


def _target_name(target: Any) -> str:
    if isinstance(target, str):
        return target
    name = getattr(target, "__name__", None)
    if name:
        return name
    return repr(target)


def _node_arg_names(args: Tuple[Any, ...]) -> List[Any]:
    out: List[Any] = []
    for arg in args:
        if isinstance(arg, fx.Node):
            out.append(arg.name)
        elif isinstance(arg, tuple):
            out.append(_node_arg_names(arg))
        else:
            out.append(repr(arg))
    return out


def import_graph(model: torch.nn.Module, trace_inputs: Tuple[Any, ...]) -> ImportedGraph:
    """Return the FX graph (and module) for a PyTorch model.

    Uses ``torch.export`` when available (the same IR ``torch.compile`` lowers
    through). Falls back to ``torch.fx.symbolic_trace`` for tiny eager modules.

    ``torch.compile`` wrappers are unwrapped first so we export the underlying
    ``nn.Module`` rather than Dynamo guard machinery.
    """
    model = _unwrap_compiled(model)
    model.eval()
    try:
        exported = torch.export.export(model, trace_inputs)
        graph_module = exported.module()
        return ImportedGraph(
            graph=graph_module.graph,
            graph_module=graph_module,
            backend="torch.export",
        )
    except Exception:
        graph_module = fx.symbolic_trace(model)
        return ImportedGraph(
            graph=graph_module.graph,
            graph_module=graph_module,
            backend="symbolic_trace",
        )


def dump_graph(imported: ImportedGraph, out_dir: Path) -> Tuple[Path, Path]:
    """Write human-readable and JSON graph dumps to *out_dir*."""
    out_dir.mkdir(parents=True, exist_ok=True)

    txt_path = out_dir / "graph.txt"
    json_path = out_dir / "graph.json"

    lines = [f"# PyVedas imported graph (backend: {imported.backend})", ""]

    readable = io.StringIO()
    with contextlib.redirect_stdout(readable):
        imported.graph_module.print_readable()
    readable_text = readable.getvalue().strip()
    if readable_text:
        lines.extend(["## GraphModule", "", readable_text, ""])

    lines.extend(["## FX nodes", ""])
    for node in imported.graph.nodes:
        target = ""
        if node.op not in ("placeholder", "output"):
            target = _target_name(node.target)
        lines.append(
            f"{node.op:16} {node.name:16} target={target} "
            f"args={_node_arg_names(tuple(node.args))}"
        )

    txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    nodes = []
    for node in imported.graph.nodes:
        nodes.append(
            {
                "name": node.name,
                "op": node.op,
                "target": _target_name(node.target) if node.op != "placeholder" else None,
                "args": _node_arg_names(tuple(node.args)),
                "kwargs": {key: repr(value) for key, value in node.kwargs.items()},
            }
        )

    payload = {
        "backend": imported.backend,
        "nodes": nodes,
    }
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return txt_path, json_path
