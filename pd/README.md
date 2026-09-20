# Tiny-Vedas physical design (RTL → GDS)

OpenROAD’s Yosys frontend is weak on SystemVerilog. This flow converts the
core to Verilog with [sv2v](https://github.com/zachjs/sv2v), then runs
[OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
(ORFS) for synthesis through GDS.

## Prerequisites

On this machine the tools live under `/tools`:

| Tool | Path |
|------|------|
| sv2v | `/tools/sv2v/bin/sv2v` |
| OpenROAD-flow-scripts | `/tools/OpenROAD-flow-scripts` |

ORFS dependencies (Yosys with slang, OpenROAD, KLayout, etc.) are on `PATH`
after sourcing `/tools/OpenROAD-flow-scripts/env.sh` (handled by the scripts
below).

Simulation deps (`make deps`) are separate from PD.

If host Yosys/OpenROAD is missing, run the same Makefile targets inside the
ORFS Docker image:

```bash
ORFS_TARGET=all PD_PLATFORM=ci-asap7 ./scripts/pd_docker.sh make rtl2gds
```

`LEC_CHECK` defaults to 0 in the container (formal LEC is optional).

## Quick start

```bash
# 1) Select CPU flavor + PDK platform → writes pd/active.mk
make config
make config HW_CONFIG=hw/presets/rv32im_scalar.yaml PD_PLATFORM=asap7

# 2) sv2v only
make sv2v

# 3) Full RTL → GDS (sv2v + ORFS)
make rtl2gds

# Partial ORFS targets (after sv2v):
make rtl2gds ORFS_TARGET=synth
make rtl2gds ORFS_TARGET=finish

# Post-route timing summary (Fmax, WNS, critical path):
make pd-report
make timing    # rtl2gds + pd-report
```

## Timing analysis

The default ASAP7 target is **3 GHz** (`target_clock_ghz` in
`pd/platforms/asap7.yaml`). After a full flow:

```bash
make rtl2gds          # through finish (route + final report)
make pd-report        # print timing summary
```

ORFS writes detailed reports under
`/tools/OpenROAD-flow-scripts/flow/reports/<platform>/tiny_vedas/base/`.
The key file is **`6_finish.rpt`**, which includes:

| Section | Meaning |
|---------|---------|
| `report_clock_min_period` | **Fmax** — max frequency from the worst setup path |
| `report_wns` / `report_worst_slack` | Slack vs your **target** clock (3 GHz) |
| `report_checks -path_delay max` | Full **setup critical path** (start/end points, per-stage delay) |

`make pd-report` parses `6_finish.rpt`, writes a short summary to
`pd/work/timing_summary.txt`, and copies ORFS layout snapshots (`.webp`) into
`pd/work/layout/` — start with `final_all.webp` for the full routed core.

To change the target frequency, edit `target_clock_ghz` (or `clock_period`) in
the platform YAML and re-run `make config`.

## Multiplier pipeline (PD experiments)

The 32-bit multiply path in `exu_mul` is a **multi-cycle** unit. Boundary flops are
in the wrapper (`a_e2_ff` / `prod_e3_ff`); SVLib `mul` may add **at most
one** internal register stage — see `rtl/include/mul_pd_config.svh`.

Production defaults (ASAP7 timing closure):

```verilog
`define MUL_PIPE_STAGE_AFTER_BOOTH 0
`define MUL_PIPE_STAGE_CSA_LR1       0
`define MUL_PIPE_STAGE_CSA_LR2       0
`define MUL_PIPE_STAGE_CSA_LR3       1   // flop after CSA layer 2 (32-bit WIDTH)
`define MUL_PIPE_STAGE_CSA_LR4       0
`define MUL_PIPE_STAGES_CPA          2   // sideband latency; CPA uses kogge_stone_pipe
```

`exu_mul` sets `CPA_ALGORITHM(2)` → **`kogge_stone_pipe`** (2-cycle CPA, one flop
between prefix-tree halves). Do not confuse with **`kogge_stone_adder`**, which is
fully combinational and used in the divider iteration loop.

**`CPA_ALGORITHM`** on SVLib `mul`:

| Value | Final adder | `PIPE_STAGES_CPA` |
|-------|-------------|-------------------|
| `0` | `adder_pipe` + RCA | Splits 64-bit sum into `NUM_ADDERS` lanes (carry flop between lanes when `>1`) |
| `1` | `adder_pipe` + 4-bit CLA | Same lane structure as RCA |
| `2` | `kogge_stone_pipe` | Ignored for structure; fixed 1 internal flop. Keep `=2` so `MUL_LAT` in `exu_mul` matches |

Legal PD sweep points (pick **one** internal flop): after Booth, after CSA LR1/LR2/LR3, or
CPA via `adder_pipe` lanes (`PIPE_STAGES_CPA=2`). Do not stack multiple hooks.
Timing sweeps:

```bash
python3 pd/scripts/sweep_mul_pipeline.py --dry-run   # list legal configs
python3 pd/scripts/sweep_mul_pipeline.py -j 8        # parallel rtl2gds (~8 min/job)
make mul-sweep                                       # -j $(nproc)
```

Each job uses an isolated ORFS `DESIGN_NICKNAME` (`tiny_vedas_<label>`) and work
tree under `pd/work/sweep/<label>/` so flows do not collide.

Non-baseline pipe settings require aligning the enabled stage with the `exu_mul`
e2/e3 cycle boundary before functional sign-off. Mixed-sign multiply (MULHSU) is
handled inside SVLib `mul` via separate multiplicand/multiplier sign controls —
regression: `asm.basic_mul`.

## What `make config` does

Reads:

- **HW preset** (`hw/presets/*.yaml`) — CPU flavor (`rv32im_scalar` or `rv32im_zve32x`)
- **PD platform** (`pd/platforms/*.yaml`) — ORFS platform, clock, synth memory sizes

Generates:

| File | Purpose |
|------|---------|
| `pd/active.mk` | Paths and variables for scripts |
| `pd/include/global.svh` | Smaller ICCM/DCCM for synthesis |
| `pd/work/orfs_config.mk` | ORFS `DESIGN_CONFIG` |
| `pd/work/constraint_<platform>.sdc` | Timing constraints |

Full 2^18-word memories live in `soc_top`, not in the synthesizable core. The PD
overlay shrinks ICCM/DCCM address widths in `pd/include/global.svh` (1024 words
by default) so memory buses are reasonably sized during synthesis.

Physical design targets **`core_gemm_top`** (`pd/rtl/core_gemm_top.sv`): the
IFU/IDU/EXU pipeline plus the GEMM engine, with ICCM/DCCM ports left as IOs
(no AXI adapters, no on-chip SRAMs). Simulation and software tests use
**`soc_top`**, which wraps the core and GEMM with AXI4 adapters and ICCM/DCCM
from `rtl/lib/mem_lib.sv`.

The default PDK is **ASAP7** (`PD_PLATFORM=asap7`). Clock periods in SDC follow
ORFS conventions for each PDK (picoseconds for ASAP7, nanoseconds for sky130).

## Flow overview

```
SystemVerilog (rtl/ + pd/rtl/core_gemm_top.sv + SVLib)
        │  sv2v (--top core_gemm_top, no memories)
        ▼
pd/work/sv2v/tiny_vedas.v
        │  ORFS (Yosys slang → OpenROAD → KLayout)
        ▼
pd/work/artifacts via ORFS results/ (linked under ORFS tree)

Simulation uses `soc_top` (core + GEMM + AXI4 CCM path) via `rtl/core_top.flist`.
```

## Layout

```
pd/
├── synth.flist          # RTL inputs (core + GEMM, no testbench)
├── rtl/core_gemm_top.sv # PD wrapper: core_top + gemm_top
├── include/             # generated global.svh overlay
├── platforms/           # PDK / tool paths per platform
├── orfs/                # checked-in SDC templates
├── scripts/
│   ├── gen_active_config.py
│   ├── sv2v.sh
│   └── rtl2gds.sh
└── work/                # generated netlists + ORFS config (gitignored)
```

## Adding a platform

1. Copy `pd/platforms/asap7.yaml` → `pd/platforms/<pdk>.yaml`
2. Add `pd/orfs/<pdk>/tiny_vedas/constraint.sdc` if needed
3. `make config PD_PLATFORM=<pdk>`

## Adding a CPU flavor

When new RTL variants land, point `HW_CONFIG` at the matching preset.
`rv32im_zve32x` keeps `cpu.kind: scalar` and turns `HAS_VECTOR` on so
`vector_top` is in `core_gemm_top` (`keep_hierarchy` on core, GEMM, and
vector). After `make rtl2gds`, `make pd-annotate` colors those three
instances into `pd/work/layout/annotated_core_gemm_vector.png`.
