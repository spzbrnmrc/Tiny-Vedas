# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""PyVedas JIT entry point: PyTorch module -> generated C + link manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Tuple

import torch
import torch.nn as nn

from .codegen import emit_c, lower_graph
from .graph_import import dump_graph, import_graph
from .hw_context import HwConfig, resolve_hw_config, select_materializer
from .registry import load_registry, validate_graph_ops


def compile_model(
    model: nn.Module,
    trace_inputs: Tuple[Any, ...],
    pyvedas_root: Path,
    out_dir: Path,
    *,
    target: bool = False,
    hw_config: HwConfig | None = None,
    gemm_scratch_bytes: int | None = None,
) -> Path:
    pyvedas_root = pyvedas_root.resolve()
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    imported = import_graph(model, trace_inputs)
    graph_txt, graph_json = dump_graph(imported, out_dir)

    hw = hw_config or resolve_hw_config(None)
    materializer = select_materializer(hw)

    registry = load_registry(pyvedas_root)
    validate_graph_ops(imported.graph, registry)
    plan = lower_graph(
        imported.graph,
        registry,
        trace_inputs,
        materializer=materializer,
        gemm_scratch_bytes=gemm_scratch_bytes,
        graph_module=imported.graph_module,
    )

    if target and plan.result_names:
        # Bake host-computed goldens so FPGA EOT implies correct outputs.
        eager = model
        if isinstance(model, nn.Module) and hasattr(model, "_orig_mod"):
            eager = model._orig_mod  # torch.compile wrapper
        with torch.no_grad():
            out_t = eager(*trace_inputs)
        if isinstance(out_t, (tuple, list)):
            tensors = list(out_t)
        else:
            tensors = [out_t]
        if len(tensors) != len(plan.result_names):
            raise RuntimeError(
                f"eager produced {len(tensors)} outputs, "
                f"graph has {len(plan.result_names)}"
            )
        goldens: list[tuple[str, tuple[int, ...]]] = []
        for name, tensor in zip(plan.result_names, tensors):
            golden_buf = materializer.materialize(f"_eot_golden_{name}", tensor)
            goldens.append((name, golden_buf.values))
        plan.result_goldens = goldens

    generated_c = out_dir / "generated.c"
    emit_c(plan, generated_c, target=target)

    manifest = {
        "generated_c": str(generated_c),
        "graph_txt": str(graph_txt),
        "graph_json": str(graph_json),
        "graph_backend": imported.backend,
        "hw_config": hw.to_dict(),
        "include_dirs": [
            str(pyvedas_root / "runtime" / "include"),
            str(pyvedas_root.parent / "sw" / "include"),
        ],
        "sources": [str(p) for p in plan.runtime_sources],
        "target": target,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return generated_c


def main() -> None:
    parser = argparse.ArgumentParser(description="PyVedas JIT compiler")
    parser.add_argument(
        "--model-spec",
        required=True,
        help="Python file defining MODEL and TRACE_INPUTS (compile-time trace tensors)",
    )
    parser.add_argument(
        "-o",
        "--out-dir",
        default="pyvedas/work/out",
        help="Output directory for generated C and manifest",
    )
    parser.add_argument(
        "--target",
        action="store_true",
        help="Emit bare-metal C for Tiny-Vedas (eot_sequence, no printf)",
    )
    parser.add_argument(
        "--hw-config",
        default=None,
        help="Hardware preset YAML (default: hw/presets/rv32im_zve32x.yaml)",
    )
    args = parser.parse_args()

    spec_path = Path(args.model_spec).resolve()
    namespace: dict[str, Any] = {}
    exec(spec_path.read_text(encoding="utf-8"), namespace)

    model = namespace["MODEL"]
    trace_inputs = namespace["TRACE_INPUTS"]
    gemm_scratch = namespace.get("GEMM_SCRATCH_BYTES")
    pyvedas_root = Path(__file__).resolve().parents[1]

    hw = resolve_hw_config(args.hw_config)
    out = compile_model(
        model,
        trace_inputs,
        pyvedas_root,
        Path(args.out_dir),
        target=args.target,
        hw_config=hw,
        gemm_scratch_bytes=None if gemm_scratch is None else int(gemm_scratch),
    )
    print(f"Generated {out}")


if __name__ == "__main__":
    main()
