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
from .memory.dram import DramImage
from .memory.materialize import DramMaterializer
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
    stream: bool = False,
    goldens: bool | None = None,
) -> Path:
    pyvedas_root = pyvedas_root.resolve()
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    imported = import_graph(model, trace_inputs)
    graph_txt, graph_json = dump_graph(imported, out_dir)

    hw = hw_config or resolve_hw_config(None)
    dram_image = None
    if stream:
        dram_image = DramImage(
            base=hw.memory.dram_base, limit=hw.memory.dram_bytes
        )
        materializer = DramMaterializer(dram_image)
    else:
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
        stream=stream,
        dram_image=dram_image,
    )

    bake_goldens = target if goldens is None else bool(goldens)
    if bake_goldens and plan.result_names:
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
            data = tensor.detach().to(torch.int32).reshape(-1)
            goldens.append((name, tuple(int(x) for x in data.tolist())))
        plan.result_goldens = goldens
        if stream:
            plan.checksum_goldens = True

    generated_c = out_dir / "generated.c"
    emit_c(plan, generated_c, target=target)
    if dram_image is not None:
        dram_image.write_hex(out_dir / "dram.hex")

    buffers = {}
    for buf in plan.memory.buffers.values():
        buffers[buf.name] = {
            "shape": list(buf.shape),
            "c_type": buf.c_type,
            "kind": buf.layout.kind,
            "offset": int(buf.layout.offset),
            "numel": int(buf.numel),
            "elem_bytes": int(buf.layout.elem_bytes),
        }
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
        "stream": stream,
        "goldens": bake_goldens,
        "input_names": list(plan.input_names),
        "result_names": list(plan.result_names),
        "ops": list(plan.op_names),
        "buffers": buffers,
        "dram_bytes_used": 0 if dram_image is None else int(dram_image.cursor),
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
    stream = bool(namespace.get("STREAM", False))
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
        stream=stream,
    )
    print(f"Generated {out}")


if __name__ == "__main__":
    main()
