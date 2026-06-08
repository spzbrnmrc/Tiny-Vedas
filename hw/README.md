# Tiny-Vedas hardware configuration

Single source of truth for **which CPU flavor** RTL, `sim_manager`, and PyVedas
are targeting. Pass a preset (or custom YAML) via `--hw-config` everywhere.

## Presets

| File | CPU | Vector unit |
|------|-----|-------------|
| `rv32im_scalar.yaml` | 4-stage in-order scalar (shipping RTL) | off |
| `vliw_vec.yaml` | Configurable VLIW | on |
| `superscalar_vec.yaml` | In-order superscalar | on |
| `ooo_vec.yaml` | Out-of-order | on |

Only `rv32im_scalar` matches implemented RTL today. Other presets are **scaffolds**
so software can be developed against a stable contract before those cores land.

## Schema (version 1)

```yaml
name: <preset_id>
version: 1
description: <human text>

cpu:
  kind: scalar | vliw | superscalar | ooo
  isa: rv32im
  issue_width: <int>
  out_of_order: <bool>

vector:
  enabled: <bool>
  width_bits: <int>
  lanes: <int>
  local_mem_bytes: <int>

memory:
  iccm_depth_words: <int>
  dccm_depth_words: <int>
  link_address: <hex>
  uart_address: <hex>
  eot_address: <hex>

software:
  materializer: flat_row_major   # PyVedas buffer layout strategy
  vectorize_min_numel: <int>     # 0 = always scalar loops
```

## Usage

```bash
# sim_manager (default = rv32im_scalar)
./scripts/with_env.sh ./tools/sim_manager.py -s verilator -n pyvedas.vector_add
./scripts/with_env.sh ./tools/sim_manager.py -s verilator -t tests/smoke.tlist \
  --hw-config hw/presets/vliw_vec.yaml

# PyVedas JIT
cd pyvedas && python3 -m jit --model-spec ../tests/pyvedas/vector_add.py \
  -o work/out --target --hw-config ../hw/presets/superscalar_vec.yaml
```

Each test run copies the resolved config to `work/<test>/hw_config.json`.

## Python API

```python
from hw import load_hw_config, list_presets

cfg = load_hw_config("hw/presets/ooo_vec.yaml")
assert cfg.has_vector_unit
assert cfg.cpu.kind.value == "ooo"
```

## Extension points

| Consumer | Reads today | Will use next |
|----------|-------------|---------------|
| **PyVedas** | `software.materializer`, `vectorize_min_numel` | tiled layouts, vector intrinsics |
| **sim_manager** | memory map, preset name in artifacts | ICCM/DCCM depths, RTL plusargs |
| **RTL** | (manual) | generate `global.svh` from preset (future) |
