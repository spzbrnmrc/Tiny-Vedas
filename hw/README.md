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

soc: default                 # hw/soc/<name>.yaml

software:
  materializer: flat_row_major   # PyVedas buffer layout strategy
  vectorize_min_numel: <int>     # 0 = always scalar loops
```

UART/EOT (and later GEMM-class accelerators) live in the **SoC device map**, not the CPU preset. `memory.uart_address` / `eot_address` on the loaded `HwConfig` are derived from that map.

## SoC device map (`hw/soc/`)

Device-tree-style YAML consumed by `make soc` / `sim_manager`. It generates:

| Artifact | Role |
|----------|------|
| `rtl/include/mmio_map.svh` | Address ranges + indices for `rtl/bus/mmio_mux.sv` |
| `sw/include/soc_defines.h` | C / preprocessed `.S` macros (`MMIO_UART_ADDR`, …) |
| `sw/include/soc_defines.inc` | Gas `.include` for `.s` tests |

```yaml
name: default
version: 1
devices:
  - name: uart
    compatible: tv,uart-tx
    role: uart                 # uart | eot | mmio | accelerator
    base: 0x00200000
    size: 4                    # bytes; decode is [base, base+size)
    access: [write]
    # module: gemm_top         # optional RTL instance name (future)
    sw:
      addr_macro: MMIO_UART_ADDR
```

Stores in any mapped range are stripped from DCCM. `role: uart` and `role: eot` are required today (TB console, sim finish, FPGA FIFO/sticky).

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
| **sim_manager** | SoC map → `soc_defines.h`, ISS EOT address | ICCM/DCCM depths, RTL plusargs |
| **RTL** | `mmio_mux` + `mmio_map.svh` from SoC YAML | instantiate `module:` accelerators |
