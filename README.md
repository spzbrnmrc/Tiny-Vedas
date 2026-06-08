# Tiny Vedas — Open Infrastructure for RISC-V AI Accelerators

Tiny Vedas is an open-source stack for designing, verifying, and bringing up RISC-V AI accelerators — from synthesizable processor RTL and spec-driven decode, through ISS/RTL co-simulation, to a PyTorch JIT that targets bare-metal firmware on the core.

**Today**, the repo ships a complete **RV32IM** reference core: a 4-stage in-order pipeline with Harvard memory, hazard handling, and end-to-end test infrastructure. **Next**, the same contracts extend to additional microarchitectures (VLIW, superscalar, out-of-order) and vector units — hardware presets and software hooks are already scaffolded in [`hw/`](hw/README.md) so RTL, simulation, and PyVedas can evolve together without breaking the workflow.

It is also used as a reference for the [free course on RISC-V Processor Design](https://youtu.be/izPdo7n1uI).

## What's in the stack

| Layer | Role |
|-------|------|
| **RTL** | Synthesizable RISC-V cores and SoC integration (`rtl/`) |
| **Verification** | Python ISS + RTL trace comparison (`tools/rv_iss.py`, `sim_manager.py`) |
| **Decode** | YAML-driven instruction tables → SystemVerilog (`open-decode-tables/`) |
| **Primitives** | Reusable arithmetic and register blocks (`SVLib/`) |
| **Software** | Bare-metal runtime, printf, assembly/C/PyTorch tests |
| **PyVedas** | `torch.compile` → C → RV32 ELF for on-core inference kernels |
| **PD** | Optional ASIC flow: sv2v + OpenROAD (`pd/`) |

## Current focus: RV32IM

The shipping RTL is a **4-stage pipelined RV32IM** processor written in SystemVerilog. It is the baseline CPU flavor (`hw/presets/rv32im_scalar.yaml`) used by CI, examples, and the course.

## Roadmap: microarchitectures and vector

Tiny Vedas is built to support **multiple CPU organizations** behind one hardware-config contract. Presets in [`hw/presets/`](hw/presets/) already describe scalar, VLIW, superscalar, and out-of-order variants with optional vector units; only `rv32im_scalar` matches implemented RTL today. As new microarchitectures land, `sim_manager`, PyVedas, and the test suite will target them through the same `--hw-config` YAML — so accelerator exploration stays one toolchain, not a fork per design.

## Features

### Architecture

- **ISA**: RISC-V RV32IM (32-bit integer + multiply/divide)
- **Pipeline**: 4-stage (IFU → IDU0 → IDU1 → EXU)
- **Memory**: Harvard architecture — separate instruction memory (ICCM) and data memory (DCCM)
- **Decode**: Spec-driven via the `open-decode-tables` submodule (YAML → SystemVerilog)
- **Verification**: Python instruction-set simulator (ISS) compared against RTL traces

### Instruction Set Support

- **Arithmetic**: ADD, SUB, ADDI, LUI, AUIPC
- **Logical**: AND, OR, XOR, ANDI, ORI, XORI
- **Shifts**: SLL, SRL, SRA, SLLI, SRLI, SRAI
- **Comparison**: SLT, SLTU, SLTI, SLTIU
- **Branches**: BEQ, BNE, BLT, BGE, BLTU, BGEU
- **Jumps**: JAL, JALR
- **Memory**: LB, LH, LW, LBU, LHU, SB, SH, SW
- **Multiply/Divide**: MUL, MULH, MULHU, MULHSU, DIV, DIVU, REM, REMU
- **System**: NOP (`addi x0, x0, 0`), ECALL (decoded; no trap handler yet — behaves as NOP)

### Advanced Features

- Register forwarding from EXU to IDU1
- Pipeline flush on taken branches and jumps
- Register scoreboard for RAW hazard detection
- Multi-cycle multiplier and divider
- Booth-encoded 32×32 multiplier with per-operand signedness (MUL / MULH / MULHU / MULHSU)
- Non-restoring divider with combinational Kogge-Stone adders on the iteration path
- Unaligned load/store support with store-to-load forwarding

## Project Structure

```
Tiny-Vedas/
├── rtl/                     # Processor RTL
│   ├── core_top.sv          # CPU pipeline (memory ports exposed)
│   ├── soc_top.sv           # core_top + ICCM/DCCM (simulation / integration)
│   ├── core_top.flist       # File list for synthesis/simulation
│   ├── ifu/                 # Instruction fetch unit
│   ├── idu/                 # Decode stages, regfile, scoreboard
│   │   ├── rv32im_decoder.sv   # Generated — do not hand-edit
│   │   └── decode_out_t.svh      # Generated — do not hand-edit
│   ├── exu/                 # ALU, MUL, DIV, LSU
│   ├── include/             # global.svh, types.svh
│   └── lib/                 # ICCM/DCCM memory models
├── dv/
│   ├── sv/                  # core_top_tb.sv, lsu_tb.sv
│   └── verilator/           # Verilator C++ harness
├── hw/                      # Hardware presets (scalar, VLIW, OoO + vector)
│   ├── presets/             # YAML configs shared by RTL/SW (see hw/README.md)
│   └── types.py             # Typed HwConfig loader
├── tests/
│   ├── asm/                 # Assembly test programs
│   ├── c/                   # C benchmarks (helloworld, iaxpy)
│   ├── elf/                 # Prebuilt ELF binaries (dhrystone)
│   ├── pyvedas/             # PyTorch → JIT model specs
│   └── smoke.tlist          # Regression test list
├── pyvedas/                 # PyTorch → Tiny-Vedas JIT
├── tools/
│   ├── sim_manager.py       # Main test runner (compile → ISS → RTL → compare)
│   └── rv_iss.py            # Reference instruction-set simulator
├── sw/vedas_printf/         # Bare-metal printf library for C tests
├── SVLib/                   # Git submodule — reusable SystemVerilog primitives
├── open-decode-tables/      # Git submodule — YAML decode table generator
├── scripts/
│   ├── install_deps.sh      # Dependency installer (`make deps`)
│   ├── env.sh               # Generated PATH + venv (by `make deps`)
│   └── with_env.sh          # Wrapper used by Makefile targets
├── .github/workflows/ci.yml # GitHub Actions CI pipeline
├── Makefile
├── requirements.txt
└── LICENSE
```

## Prerequisites

| Tool | Purpose |
|------|---------|
| **Verilator** | RTL simulation (primary; used in CI) |
| **riscv64-unknown-elf-gcc** | Bare-metal cross-compiler for test programs (RV32IM / ILP32) |
| **Python 3** | `sim_manager.py`, `rv_iss.py`, decode generation |
| **Xilinx Vivado** (optional) | XSim simulation — only needed if you prefer `make smoke` over Verilator |

Tested on Ubuntu 22.04 and 24.04. Other Linux distributions should work with equivalent packages installed manually.

## Quick Start

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/siliscale/Tiny-Vedas.git
cd Tiny-Vedas
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### 2. Install dependencies

On Ubuntu, `make deps` installs everything needed for simulation and verification:

- System build packages (`build-essential`, Verilator build deps)
- Python virtual environment with packages from `requirements.txt`
- Prebuilt **RISC-V GNU bare-metal toolchain** (`riscv64-unknown-elf-gcc`) into `.local/riscv/`
- Latest stable Verilator compiled from source into `.local/verilator/`

```bash
make deps
```

`make deps` also generates `scripts/env.sh` (PATH + venv) and verifies the toolchain. All Makefile test targets use it automatically via `scripts/with_env.sh`, so CI and local runs work without manual setup.

For interactive shells, source the environment once per session:

```bash
source scripts/env.sh
riscv64-unknown-elf-gcc --version
verilator --version
```

Override pinned versions if needed:

```bash
RISCV_TOOLCHAIN_VERSION=2026.06.05 make deps   # default
VERILATOR_TAG=v5.048 make deps                   # pin a specific Verilator release
FORCE_RISCV_TOOLCHAIN_REINSTALL=1 make deps      # re-download toolchain
FORCE_VERILATOR_REBUILD=1 make deps              # rebuild Verilator
```

Do **not** run `make deps` with `sudo` — only the apt step needs elevated privileges. If a previous `sudo make deps` left `deps/verilator` root-owned, fix ownership then rebuild:

```bash
sudo chown -R "$USER:$USER" deps/verilator
FORCE_VERILATOR_REBUILD=1 make deps
```

### 3. Run the smoke regression

```bash
# Verilator (recommended; same as CI)
make smoke-verilator

# Xilinx XSim (requires Vivado — optional)
make smoke
```

### 4. Run a single test

```bash
./tools/sim_manager.py -s verilator -n asm.basic_alu_r
./tools/sim_manager.py -s verilator -n c.helloworld
./scripts/with_env.sh ./tools/sim_manager.py -s verilator -n pyvedas.vector_add
```

## RISC-V GNU Toolchain

Tiny Vedas compiles bare-metal test programs with `riscv64-unknown-elf-gcc` using `-march=rv32im -mabi=ilp32`. Do **not** use the Linux cross-compiler (`riscv64-linux-gnu-gcc`) or distribution packages that lack newlib — they will not produce working bare-metal ELFs.

### Automatic install (recommended)

`make deps` downloads a prebuilt **riscv64-unknown-elf** toolchain from the [riscv-collab/riscv-gnu-toolchain releases](https://github.com/riscv-collab/riscv-gnu-toolchain/releases) page and installs it to `.local/riscv/`. The Ubuntu series (22.04 or 24.04) is detected automatically.

### Manual install

1. Go to [riscv-gnu-toolchain releases](https://github.com/riscv-collab/riscv-gnu-toolchain/releases).
2. Download the **`riscv64-elf-ubuntu-<version>-gcc.tar.xz`** archive matching your Ubuntu version.
3. Extract and add to your `PATH`:

```bash
# Example for Ubuntu 22.04, release 2026.06.05
wget https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2026.06.05/riscv64-elf-ubuntu-22.04-gcc.tar.xz
mkdir -p ~/.local
tar -xJf riscv64-elf-ubuntu-22.04-gcc.tar.xz -C ~/.local

# Add to ~/.bashrc
export PATH="$HOME/.local/riscv/bin:$PATH"
source ~/.bashrc
```

4. Verify RV32IM support:

```bash
riscv64-unknown-elf-gcc --version
echo 'int main(void) { return 0; }' | riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -x c -
```

### Build from source (not recommended for CI)

If prebuilt binaries are unavailable for your platform, follow the build instructions in the [riscv-gnu-toolchain README](https://github.com/riscv-collab/riscv-gnu-toolchain). Configure for bare metal:

```bash
./configure --prefix=/opt/riscv --with-arch=rv32im --with-abi=ilp32
make -j$(nproc)
```

This takes a long time. Prefer the prebuilt nightly releases for development and CI.

## Running Tests

All tests are driven by `tools/sim_manager.py`. Tests are named `<type>.<name>`:

| Prefix | Source | Example |
|--------|--------|---------|
| `asm.` | `tests/asm/<name>.s` | `asm.basic_mul` |
| `c.` | `tests/c/<name>.c` | `c.helloworld` |
| `elf.` | `tests/elf/<name>` (prebuilt) | `elf.dhrystone` |
| `pyvedas.` | `tests/pyvedas/<name>.py` (JIT → ELF) | `pyvedas.vector_add` |

### sim_manager.py usage

```
./scripts/with_env.sh ./tools/sim_manager.py -s <simulator> (-n <test> | -t <task-list>)

  -s, --simulator   verilator | xsim
  -n, --test-name   Run a single test (e.g. asm.basic_alu_r)
  -t, --task-list   Run all tests listed in a file (e.g. tests/smoke.tlist)
  --hw-config       Hardware preset YAML (default: hw/presets/rv32im_scalar.yaml)
```

`make smoke-verilator` and `make smoke` invoke `with_env.sh` automatically.

### Makefile targets

| Target | Command |
|--------|---------|
| `make deps` | Install system packages, Python venv, RISC-V toolchain, and Verilator |
| `make smoke-verilator` | Run the smoke regression via Verilator (CI default) |
| `make smoke` | Run the smoke regression via XSim (requires Vivado) |
| `make decodes` | Regenerate `rtl/idu/rv32im_decoder.sv` from YAML |
| `make clean` | Remove build artifacts (`work/`, `obj_dir/`, logs, VCDs) |

### Per-test output

Each test writes artifacts to `work/<test>/`:

| File | Contents |
|------|----------|
| `iss.log` | Golden ISS execution trace |
| `rtl.log` | RTL architectural trace |
| `sim.log` | Simulator stdout and comparison errors |
| `console.log` | Program UART output |
| `stats.txt` | IPC/CPI performance metrics |
| `core_top.vcd` | Waveform (Verilator only) |

## Verification

Tiny Vedas uses **co-simulation**: a Python ISS generates a golden trace, the RTL simulator produces its own trace, and `sim_manager.py` compares them instruction by instruction (PC, opcode, register writes, memory stores, branches).

Programs signal completion by storing `0xdeadbeef` to address `0x10000000`. See `tests/asm/eot_sequence.s`.

## Arithmetic units

### Multiply (`rtl/exu/exu_mul.sv` → SVLib `mul`)

The multiply unit is a **Booth-encoded** 32×32 multiplier. Operands enter at EXU
stage e2; the 64-bit product is registered at e3 and written when sideband
latency (`MUL_LAT`) expires.

| RV32M instruction | rs1 sign | rs2 sign |
|-------------------|----------|----------|
| MUL, MULH         | signed   | signed   |
| MULHU             | unsigned | unsigned |
| MULHSU            | signed   | unsigned |

Inside `mul`, the **signed operand is always the multiplicand** and the
**unsigned operand is Booth-scanned as the multiplier**. When rs1 is unsigned
and rs2 is signed, operands are swapped (product is commutative). Separate
controls drive multiplicand sign extension (`mc_sign`) and unsigned-multiplier
correction (`mult_unsign`); a single global unsigned flag is not sufficient for
MULHSU.

Pipeline placement is configured in `rtl/include/mul_pd_config.svh` (included by
`exu_mul`). At most **one** internal register stage should be enabled for PD
experiments — see [pd/README.md](pd/README.md).

**Final CPA** (`CPA_ALGORITHM` on SVLib `mul`):

| Value | Module | Notes |
|-------|--------|-------|
| `0` | `adder_pipe` + RCA | `PIPE_STAGES_CPA` splits width |
| `1` | `adder_pipe` + 4-bit CLA | Default for generic builds |
| `2` | `kogge_stone_pipe` | 2-cycle CPA, **one flop** mid prefix tree; production `exu_mul` uses this |

### Divide (`rtl/exu/div.sv`)

| Path | When | Latency |
|------|------|---------|
| **Fast** | Divide by zero/one, zero dividend, signed overflow, or both magnitudes ≤4 bits (`small_div`) | 1 cycle after issue |
| **Slow** | Everything else — 32-step non-restoring divider on absolute magnitudes | ~33 cycles |

The slow path uses **combinational** `kogge_stone_adder` instances for the
per-iteration trial add/subtract and remainder correction. Do **not** use
`kogge_stone_pipe` here — that module has a pipeline register and is reserved
for the multiplier CPA.

### SVLib adders (`SVLib/src/arith/`)

| Module | Registers | Use |
|--------|-----------|-----|
| `adder` | No | Generic wrapper: `ALGORITHM` 0=RCA, 1=CLA, 2=Kogge-Stone (comb.) |
| `kogge_stone_adder` | No | Combinational Kogge-Stone prefix adder (power-of-2 width) |
| `kogge_stone_pipe` | One | Pipelined Kogge-Stone (prefix tree split across two cycles) |
| `adder_pipe` | Optional | Multi-lane pipelined CPA for non-Kogge multiplier configs |

See [SVLib/README.md](SVLib/README.md) for the full library inventory.

### Smoke regression (`tests/smoke.tlist`)

Smoke tests cover ALU, forwarding, multiply, divide (`asm.basic_div`,
`asm.div_regression`), load/store, branches, jumps, C programs, PyVedas JIT tests
(`pyvedas.{vector,matrix,tensor}_{add,mul}`), and Dhrystone.

## Memory Map

### Processor memories

| Memory | Depth | Width | Notes |
|--------|-------|-------|-------|
| ICCM (instructions) | 2^18 words | 32-bit | Loaded from ELF `.text` section |
| DCCM (data) | 2^18 words | 32-bit | Loaded from `.data`, `.rodata`, `.bss`, etc. |

Configured in `rtl/include/global.svh`.

### Software-visible addresses

| Address | Purpose |
|---------|---------|
| `0x00100000` | Default link address for test programs (`-Wl,-Ttext=0x100000`) |
| `0x00200000` | MMIO UART — bare-metal `printf` output (`sw/vedas_printf`) |
| `0x10000000` | End-of-test flag — write `0xdeadbeef` to halt simulation |
| `0x80000000` | Default initial stack pointer (register x2) |

The reset vector is taken from the ELF `_start` symbol, not hardcoded.

## Decode Table Generation

Instruction decode logic is generated from YAML, not hand-written. The source of truth is `open-decode-tables/tables/rv32im.yaml`.

```bash
make decodes
```

This regenerates:

- `rtl/idu/rv32im_decoder.sv`
- `rtl/idu/decode_out_t.svh`

To add or modify instructions, edit the YAML in the `open-decode-tables` submodule, commit and push there, then update the submodule pointer in this repo and run `make decodes`.

## Writing Tests

### Assembly test

Create `tests/asm/my_test.s`:

```asm
    .globl   _start
    .section .text

_start:
    li   x1, 42
    add  x2, x1, x1
    .include "eot_sequence.s"
```

Run with:

```bash
./tools/sim_manager.py -s verilator -n asm.my_test
```

### C test

Create `tests/c/my_test.c` using `vedas_printf` for output. `sim_manager.py` compiles `sw/vedas_printf/vedas_printf.c` alongside the test with `-march=rv32im -mabi=ilp32 -nostdlib -lgcc` (required by the prebuilt bare-metal toolchain). The end-of-test sequence comes from `tests/c/asm_functions/eot_sequence.s`.

### Python test (PyVedas)

PyVedas tests are **model spec files** under `tests/pyvedas/`. Each file describes a small `torch.compile` module and concrete trace inputs. `sim_manager.py` JIT-compiles the model to C, links it with the PyVedas runtime, builds an RV32 ELF, and runs the usual ISS/RTL comparison.

**Prerequisites:** run `make deps` once — it installs CPU PyTorch into the repo `venv/` (used automatically by `sim_manager.py`). For JIT-only debugging you can also use `pyvedas/.venv`; see [pyvedas/README.md](pyvedas/README.md).

Create `tests/pyvedas/my_add.py`:

```python
"""PyVedas smoke test: elementwise add."""

import torch


class MyAdd(torch.nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return x + y


MODEL = torch.compile(MyAdd())
TRACE_INPUTS = (
    torch.tensor([1, 2, 3, 4], dtype=torch.int32),
    torch.tensor([10, 20, 30, 40], dtype=torch.int32),
)
```

| Symbol | Purpose |
|--------|---------|
| `MODEL` | `torch.compile` module exported by the JIT |
| `TRACE_INPUTS` | Tuple of concrete tensors — used for `torch.export` tracing **and** to bake static buffer values into `generated.c` |

**Constraints today**

- Use **`torch.int32`** tensors (bare-metal target has no soft-float).
- Every graph op must have a **1:1 entry** in `pyvedas/runtime/ops.yaml` with a matching C kernel (e.g. `aten.add.Tensor`, `aten.mul.Tensor`). Adding a new op requires a registry entry and runtime implementation — see [pyvedas/README.md](pyvedas/README.md).

Run with:

```bash
./scripts/with_env.sh ./tools/sim_manager.py -s verilator -n pyvedas.my_add
```

Add the test name to `tests/smoke.tlist` to include it in `make smoke-verilator`:

```
pyvedas.my_add
```

**What happens under the hood**

1. JIT (`pyvedas/jit`) exports the graph and writes `work/pyvedas.my_add/generated.c`, `graph.txt`, and `manifest.json`.
2. The RISC-V linker builds `test.elf` from `generated.c`, runtime sources from the manifest, and `eot_sequence.s`.
3. ISS and Verilator traces are compared like any other test.

Inspect JIT output on failure: `work/pyvedas.my_add/jit.log`, `compile.log`, `sim.log`.


The design is synthesizable. Use `rtl/core_top.flist` as the file list for FPGA
flows. The file list references the `SVLib` submodule and sets `$PROJ` to the
repository root.

For ASIC physical design (SystemVerilog → Verilog via
[sv2v](https://github.com/zachjs/sv2v), then OpenROAD-flow-scripts), see
[pd/README.md](pd/README.md):

```bash
make config                    # CPU flavor + PDK platform
make sv2v                      # convert RTL only
make rtl2gds                   # sv2v + synthesis/place/route/GDS
make rtl2gds ORFS_TARGET=synth # stop after synthesis
```

```bash
make decodes   # ensure decoder is up to date before synthesis
```

## Performance Scoreboard

IPC values from RTL simulation (see `work/<test>/stats.txt` after a run):

| Benchmark | IPC |
|:---------:|:---:|
| c.helloworld | 0.6177 |
| c.iaxpy | 0.4564 |
| elf.dhrystone | 0.5078 |

## Submodules

| Submodule | Repository | Purpose |
|-----------|------------|---------|
| `SVLib` | [siliscale/SVLib](https://github.com/siliscale/SVLib) | Registers, program counter, arithmetic primitives |
| `open-decode-tables` | [siliscale/open-decode-tables](https://github.com/siliscale/open-decode-tables) | YAML → SystemVerilog decode generator |

After pulling submodule updates:

```bash
git submodule update --init --recursive
make decodes
```

## Continuous Integration

GitHub Actions runs on every push and pull request to `main`. The workflow (`.github/workflows/ci.yml`) mirrors a from-scratch developer setup:

1. Checkout with submodules
2. `make deps` — system packages, Python venv, RISC-V toolchain, Verilator, `scripts/env.sh`
3. `make decodes` — regenerate the instruction decoder
4. `make smoke-verilator` — full smoke regression (`tests/smoke.tlist`)

No Vivado license is required. `make deps` writes `scripts/env.sh`; subsequent `make` targets load it automatically — no manual `PATH` or `source venv/bin/activate` in CI.

If CI fails, check the job log for the failing test name, then reproduce locally with:

```bash
make deps   # if not already done
./scripts/with_env.sh ./tools/sim_manager.py -s verilator -n <test.name>
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes and add tests
4. Run `make smoke-verilator` before submitting
5. Submit a pull request

If you change instruction decode, update `open-decode-tables/tables/rv32im.yaml` in the submodule, push there, then bump the submodule pointer in this repo.

## Business inquiries

For partnerships, consulting, custom accelerator work, or commercial licensing questions, contact **[marco@siliscale.com](mailto:marco@siliscale.com)**.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

- [NOTICE](NOTICE) — attribution for this repo and bundled submodules
- [THIRD_PARTY.md](THIRD_PARTY.md) — dev-only tools vs shipped components

SPDX: `Apache-2.0`
