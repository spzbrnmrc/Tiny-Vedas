# PyVedas — PyTorch → Tiny-Vedas JIT

PyVedas bridges PyTorch models and the Tiny-Vedas RISC-V core. The JIT walks a
`torch.compile` / `torch.export` GraphModule and emits a **host-testable C program**
that calls into a small runtime library ("our CUDA") implemented as C, assembly,
or prebuilt ELF objects.

## Hardware presets

PyVedas reads the same YAML presets as `sim_manager` (`hw/presets/*.yaml`).
Pass `--hw-config` to select a CPU/vector flavor; the resolved config is stored
in `manifest.json` under `hw_config`.

```bash
python3 -m jit --model-spec ../tests/pyvedas/vector_add.py -o work/out \
  --target --hw-config ../hw/presets/vliw_vec.yaml
```

Materializer selection lives in `jit/hw_context.py` (today always
`flat_row_major`; vector-aware layouts plug in per preset).

## Design principles

**1:1 op mapping.** Every `call_function` node in the GraphModule must have
exactly one entry in `runtime/ops.yaml`. The YAML key is the graph op name
(e.g. `aten.add.Tensor`). No aliases, no per-rank variants — one graph op, one
implementation file.

**Vectors, not tensors.** PyTorch has tensors; the runtime does not. The JIT
flattens compile-time trace inputs into row-major `static` buffers. Each runtime
function receives `(const T *a, const T *b, T *out, size_t n)` — flat vectors
only. Rank and shape are compile-time comments in `generated.c`. The C kernels
will be revisited when Tiny-Vedas has hardware vector support.

## Architecture

```
PyTorch model
    │  torch.compile / torch.export
    ▼
GraphModule (aten.add.Tensor, …)
    │  1:1 registry lookup
    ▼
generated.c  +  runtime/c/<op>.c
    │  gcc (host)  or  riscv64-unknown-elf-gcc (target)
    ▼
native binary / ELF  →  sim_manager / Tiny-Vedas
```

### Runtime registry (`runtime/ops.yaml`)

| Field | Purpose |
|-------|---------|
| YAML key | GraphModule op name (`aten.add.Tensor`) — must match exactly |
| `symbol` | C function called from generated code |
| `codegen` | JIT lowering template (`elementwise_binary`, …) |
| `sources` | Link artifacts: `c`, `asm`, or `elf` |

If the graph contains an op with no registry entry, the JIT **errors**.

### Trace inputs vs tests

Each model spec file (`tests/pyvedas/*.py`) defines:

| Symbol | Role |
|--------|------|
| `MODEL` | `torch.compile` module to export |
| `TRACE_INPUTS` | Concrete tensors for `torch.export` **and** for baking static buffer values |

`TRACE_INPUTS` are **not** runtime parameters. They are compile-time fixtures:
PyTorch needs real tensors to trace the graph (shapes, dtypes, op wiring), and
PyVedas reuses those same tensors to fill `static` arrays in `generated.c`.

The smoke *test* is the full pipeline (JIT → ELF → ISS/RTL). The trace inputs
happen to live in the same `.py` file today; later they could be split out or
generated separately without changing the runtime contract.

## Quick start

```bash
cd pyvedas
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

make run-host
```

### JIT only

```bash
python3 -m jit --model-spec ../tests/pyvedas/vector_add.py -o work/out
```

Artifacts in `work/out/`:

- `generated.c` — generated program
- `graph.txt` / `graph.json` — imported GraphModule dump
- `manifest.json` — link inputs

## Adding a new GraphModule op

1. Add a YAML key matching the FX node target (see `graph.json` for names).
2. Implement `runtime/c/<op>.c` (or asm/elf) and declare the symbol in `pyvedas.h`.
3. Add a codegen handler in `jit/codegen.py` if the signature pattern is new.

## Target (Tiny-Vedas)

```bash
./scripts/with_env.sh ./tools/sim_manager.py -s verilator -n pyvedas.vector_add
```

Smoke tests: `pyvedas.{vector,matrix,tensor}_{add,mul}` — rank varies per test,
but each op lowers 1:1 to `aten.add.Tensor` or `aten.mul.Tensor`.

## Layout

```
pyvedas/
├── jit/
│   ├── memory/          # buffer planning — primary SoC/tiling extension point
│   │   ├── types.py     # StaticBuffer, BufferLayout, MemoryPlan
│   │   ├── materialize.py  # trace tensor → StaticBuffer strategies
│   │   └── emit.py      # MemoryPlan → C static declarations
│   ├── codegen.py       # graph lowering orchestration
│   ├── codegen_handlers.py  # per-op C emission (elementwise_binary, …)
│   ├── graph_import.py  # torch.export → GraphModule
│   └── registry.py      # 1:1 ops.yaml loader
├── runtime/
│   ├── include/         # pyvedas.h
│   ├── c/               # one file per GraphModule op
│   ├── ops.yaml         # 1:1 op registry
│   └── elf/             # prebuilt kernels (future)
└── work/                # generated output (gitignored)
```

### Memory module (where tiling will live)

| Component | Responsibility |
|-----------|----------------|
| `BufferMaterializer` | Trace tensor → `StaticBuffer` (swap for tiled layouts) |
| `BufferLayout` | Physical view (`flat_row_major` today; tiled/DCCM later) |
| `MemoryPlan` | Owns all buffers; `allocate_uninitialized` for outputs |
| `emit_static_buffers` | Renders the memory plan as C `static` arrays |

To add tiling: subclass `BufferMaterializer` or add a post-pass on `MemoryPlan`
that rewrites `BufferLayout` and changes `emit.py` — without touching op handlers
or the runtime `(ptr, n)` contract.

## License

Apache License 2.0 — see [LICENSE](../LICENSE), [NOTICE](../NOTICE), and
[THIRD_PARTY.md](../THIRD_PARTY.md).
