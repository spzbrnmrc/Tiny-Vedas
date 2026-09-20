# Tiny-Vedas hardware configuration

Single source of truth for **which CPU flavor** RTL, `sim_manager`, and PyVedas
are targeting. Pass a preset (or custom YAML) via `--hw-config` everywhere.

## Presets

| File | CPU | Vector unit |
|------|-----|-------------|
| `rv32im_scalar.yaml` | 4-stage in-order scalar (shipping RTL) | off |
| `rv32im_zve32x.yaml` | same core + v1 vector box (VLEN=512, DLEN=128) | on |
| `rv32im_superscalar_2x.yaml` | 2-wide issue scaffold | off |

`rv32im_zve32x` is the CI/sim default and the Alveo U280 overlay
(`make fpga` / `make fpga_smoke`). `rv32im_scalar` is opt-in via
`HW_CONFIG`. Vector rows in `tests/smoke.tlist` are predicated on
`vector.enabled` (on for the default preset).

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
  width_bits: <int>          # VLEN; 0 if off
  dlen_bits: <int>           # execute beat; 0 if off
  lanes: <int>
  local_mem_bytes: <int>

memory:
  iccm_depth_words: <int>
  dccm_depth_words: <int>    # 128-bit DCCM lines (65536 = 1 MiB)
  link_address: <hex>

soc: default                 # hw/soc/<name>.yaml

software:
  materializer: flat_row_major   # PyVedas buffer layout strategy
  vectorize_min_numel: <int>     # 0 = always scalar loops
```

UART, EOT, and GEMM live in the **SoC device map**, not the CPU preset. `memory.uart_address` / `eot_address` on the loaded `HwConfig` are derived from that map.

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
    sw:
      addr_macro: MMIO_UART_ADDR
  - name: gemm
    compatible: tv,gemm
    role: accelerator
    base: 0x00300000
    size: 4096
    access: [read, write]
    module: gemm_top           # RTL instance in soc_top
    sw:
      addr_macro: MMIO_GEMM_ADDR
```

Stores in any mapped range are stripped from DCCM. `role: uart` and `role: eot` are required today (TB console, sim finish, FPGA FIFO/sticky).

## Usage

```bash
# sim_manager (default = rv32im_zve32x)
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
| **RTL** | `mmio_mux` + `mmio_map.svh`; `soc_top` instantiates `module: gemm_top` | additional `module:` accelerators |
