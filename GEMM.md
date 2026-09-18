# GEMM on Tiny Vedas

**An 8×8 int8 matrix engine, a RISC-V core that programs it, a PyTorch JIT that tiles against on-chip memory — and the same design running on an Alveo card and in ASAP7 GDS.**

Tiny Vedas is an open stack for RISC-V AI accelerators. The GEMM work is the first time that stack is a *compute* story, not only a CPU story: PyTorch custom op → bare-metal ELF → MMIO START → systolic array → DCCM result, checked against a Python ISS, Xilinx XSim, a real FPGA, and an OpenROAD layout.

This note is the source for posts. The facts are below; punchy excerpts are at the end.

---

## The claim

Most “tiny GEMM” demos stop at a PE array in a testbench. This one does not.

| Layer | What shipped |
|-------|----------------|
| **Datapath** | 8×8 output-stationary PEs, `int8 × int8 → int32`, K-tile 32 |
| **Engine** | CSR + packed AXI4 DMA + tile scheduler in `gemm_top` |
| **CPU** | RV32IM 4-stage core, `accel_hold` for the duration of one START |
| **Memory** | A/B/C live in DCCM. GEMM is a second master on the same SRAM. |
| **Compiler** | `torch.compile` path emits `pyvedas::gemm_mmio`; JIT plans tiles vs DCCM, not vs the PE array |
| **Sim** | ISS applies a full matmul on START; RTL walks hardware tiles; traces must match |
| **FPGA** | Alveo U280 bitstream, host halt-and-load, card smoke of GEMM ELFs |
| **Silicon PD** | `core_gemm_top` through OpenROAD on ASAP7 — CPU + GEMM, memories as IOs |

One START is one 2-D GEMM: write pointers and `(M, N, K)`, poke CTRL, wait. Hardware already micro-tiles that job. Software only splits when the *problem* does not fit on-chip memory — or when rank > 2.

That split is the whole design.

---

## Why two kinds of tiling

Mixing them up produces a compiler that re-implements the PE array in software.

**Hardware already micro-tiles one 2-D job.** The array is 8×8, K-tile 32. `gemm_top` walks M, then N, then K. A 32×32 or 128×128 that still lives in DCCM is still **one START**. The engine pads remainders with zeros. PyVedas must not emit an 8×8 nest for a 128×128 that already fits.

**PyVedas tiles against memory and rank.** Pack scratch used to be a static 256×256 int8 buffer for the *whole* matrix. Anything larger hung. Rank > 2 was a hard JIT error. The compiler’s job is:

1. **Fits DCCM + pack scratch, rank-2** — one START. Hardware tiles. Leave it alone.
2. **Does not fit** — loop M/N output tiles and K panels. Each panel is a hardware GEMM. K panels accumulate in software because hardware is overwrite (`C = A @ B`), not `C +=`.
3. **Batch / `bmm` / leading dims** — not a bigger systolic array. It is a loop of 2-D GEMMs over broadcast batch dims (numpy / `torch.matmul` rules). Each slice may still need (2).

Software tiles are PE/K-aligned (8 and 32) except remainders. The planner maximizes work per START (`m_t × n_t × k_t`), then prefers larger `k_t` so there are fewer software accumulates.

```
  PyTorch  gemm_mmio(A, B)
       │
       ▼
  JIT: fit or tile vs DCCM budget
       │  one-shot                 │  memory tiles + batch loop
       ▼                           ▼
  generated.c  ──►  pyvedas_gemm_job  ──►  CSRs  ──►  gemm_top
                                                      │
                                         8×8 OS array + K=32 walk
                                                      │
                                         packed AXI INCR DMA ↔ DCCM
```

---

## Hardware

RTL lives in [`rtl/accel/`](rtl/accel/). The public contract is in [`rtl/include/gemm_csrs.svh`](rtl/include/gemm_csrs.svh) and [`sw/include/gemm_csrs.h`](sw/include/gemm_csrs.h).

### PE array

Each `gemm_pe` is a signed int8 MAC into an int32 accumulator, using the same SVLib Booth multiplier as the core (`WIDTH=8`). The datapath is output-stationary: PE `(i, j)` keeps `C[i, j]` and sees `A[i, k]` and `B[k, j]` as `k` steps. One K-index per cycle, then a drain that matches multiplier pipe latency.

Unused lanes are zeros. Odd `(M, N, K)` is a first-class remainder, not a software-only path.

### Scheduler

`gemm_top` is a small FSM: **IDLE → FILL → ARM → COMPUTE → STORE → NEXT → DONE**.

- FILL: DMA packed A/B tiles into ping-pong SRAMs.
- COMPUTE: fire the array; if more K remains, flip ping, keep the accumulator, fetch the next K panel.
- STORE: write the 8×8 (or remainder) int32 C tile back to DCCM.
- NEXT: advance N, then M; reset K and accumulators.

Ping-pong A/B buffers are already wired. The scheduler is still fill → compute → store. Overlapping the next fill with compute is leftover RTL, not this pass.

### DMA

Two AXI4 masters on 32-bit DCCM:

| Port | Job |
|------|-----|
| m0 | A reads (along K) and C writes (int32 along N) |
| m1 | B reads (along N) |

Bursts are packed INCR. A K-tile of 32 int8s is 8 beats when 4-byte aligned; an N-tile of 8 int8s is 2 beats; a C row is `n_tile` int32 beats. One outstanding burst per port. Addresses increment; the only `m0*K` / `k0*N` math is flopped at burst start. Remainders unpack in the engine.

That packed rewrite mattered for PD: combinational address math on the DMA was the critical path.

### Programming model

Base `0x00300000`:

| Offset | Register |
|--------|----------|
| `0x00` | BASE_A |
| `0x04` | BASE_B |
| `0x08` | BASE_C |
| `0x0C` | M |
| `0x10` | N |
| `0x14` | K |
| `0x18` | CTRL — bit0 START, bit1 soft reset |
| `0x1C` | STATUS — bit0 BUSY, bit1 DONE |

Rules that firmware must get right:

- One START = one 2-D overwrite GEMM. No new CSRs for tiling.
- The core is held via `accel_hold` for the job. **Do not poll STATUS before reading C** — the hold already means the store finished.
- DONE is sticky until the next START. START re-inits tile indices, ping, and accumulators. CSRs persist; A/B/C buffers are not wiped.
- Multi-job in one ELF is required (`tests/c/gemm_multi.c`): remainders, K > 32, then a short K=1 job so leftover `k_tile` / `clear_acc` cannot silently keep the previous panel.

Firmware examples: [`tests/asm/gemm_8x8.s`](tests/asm/gemm_8x8.s), [`tests/c/gemm_8x8.c`](tests/c/gemm_8x8.c), [`tests/c/gemm_multi.c`](tests/c/gemm_multi.c).

---

## Compiler tiling

PyVedas maps `pyvedas::gemm_mmio` 1:1 through [`pyvedas/runtime/ops.yaml`](pyvedas/runtime/ops.yaml). Eager golden is `torch.matmul` on int32 containers that hold int8 values.

The planner is [`pyvedas/jit/memory/gemm_tiles.py`](pyvedas/jit/memory/gemm_tiles.py), kept in lockstep with C in [`pyvedas/runtime/c/gemm_tile.c`](pyvedas/runtime/c/gemm_tile.c) (host unit tests only). Tile sizes are **constants baked into `generated.c`**. The core ELF does not re-plan at runtime.

Budget, roughly:

- DCCM = 1 MiB (262144 × 4 bytes) — same as sim / Alveo.
- 64 KiB reserved for firmware / live tensors.
- Pack scratch capped at 128 KiB, and sized to **one hardware-facing tile**, not the full problem. That is what killed the 256² whole-matrix cap.

`choose_tile` searches PE/K-aligned candidates plus the full dim. `plan_gemm_jobs` expands `(M, N, K)` into `(m0, n0, k0, m_t, n_t, k_t)` STARTs.

Codegen ([`pyvedas/jit/codegen_handlers.py`](pyvedas/jit/codegen_handlers.py)):

- Rank-2 one-shot → a single `pyvedas_gemm_job(...)`.
- Rank-2 that does not fit → `for m0 / n0 / k0` with remainder clamps.
- Rank > 2 → broadcast-aware batch loops, then the same 2-D helper per slice.

Runtime ([`pyvedas/runtime/c/gemm_mmio.c`](pyvedas/runtime/c/gemm_mmio.c)) packs int32→int8 A/B for the tile, STARTs, then either:

- writes C directly when the tile is a full-width first K panel (hardware C stride matches), or
- GEMMs into aligned scratch and scatters, **adding** when `k0 != 0`.

No RTL accumulate bit. Software add first.

---

## Proof

Same contracts, three places.

### ISS vs RTL

[`tools/rv_iss.py`](tools/rv_iss.py) treats a START as an atomic `gemm_int8` ([`tools/gemm_ref.py`](tools/gemm_ref.py)). Multi-START sequences from the compiler must match RTL the same way any other MMIO program does. `make smoke` / `tests/gemm.tlist` is the SoC path.

Standalone array + DMA: `make gemm-directed`, `make gemm-cosim` (directed + 100 random seeds at 8/32/64/128), `make gemm-perf`.

### Tests

| Test | What it proves |
|------|----------------|
| `asm.gemm_8x8` / `c.gemm_8x8` | Bare MMIO, 8×8 identity-scale golden |
| `c.gemm_multi` | Five jobs: 8×8, 5×3 remainder, K=40 ping-flop, reuse buffers, K=1 leftover-state |
| `pyvedas.gemm_mmio` | JIT 8×8, one START |
| `pyvedas.gemm_mmio_32` | 32×32 still one-shot (hardware tiles) |
| `pyvedas.gemm_mmio_128` | 128×128 still one-shot |
| `pyvedas.gemm_mmio_tiled` | 32×32 forced to 8×8×32 pack budget → software M/N loops |
| `pyvedas.gemm_mmio_oversize` | 512×8×257 — larger than the old 256² pack; K-splits |
| `pyvedas.gemm_bmm` | 4×8×8 batch |
| `pyvedas.gemm_broadcast` | `(3,1,8,8) @ (8,8)` |
| `pyvedas.gemm_bmm_tiled` | 2×32×32, each slice also memory-tiled |

Unit tests lock Python planner ↔ C planner and assert that codegen emits constants, not a runtime search (`tests/unit/test_gemm_tiles.py`, `test_gemm_codegen.py`, `gemm_tile_host.c`).

### FPGA

Alveo U280: QDMA BAR2, 32 KiB ICCM, **1 MiB DCCM**, core + GEMM at 100 MHz. Host halt-and-load; GEMM CSRs are SoC MMIO (`0x00300000`), not a BAR window. ILA on GEMM START / DMA / DONE / hold.

Card smoke includes `asm.gemm_8x8`, `c.gemm_8x8`, `c.gemm_multi`, `pyvedas.gemm_mmio`. Pass is EOT (and UART golden when defined). FPGA halt between host tests resets core + GEMM + DCCM AXI slave.

### GDS

PD target is [`pd/rtl/core_gemm_top.sv`](pd/rtl/core_gemm_top.sv): CPU + GEMM, ICCM/DCCM left as IOs. sv2v → OpenROAD-flow-scripts, ASAP7.

Routed snapshot (`pd/work/layout/annotated_core_gemm_routed.png`): **core ~3.5 kµm², GEMM ~20.4 kµm²**. The array is most of the dielet. Timing closure is *not* claimed — post-route Fmax on this drop sits around **1.05 GHz**, critical path on DMA `csr_n → awaddr`. The 3 GHz ASAP7 target is a PD experiment, not a GEMM sign-off.

---

## What this is not (yet)

Honest scope keeps the posts honest.

- **No fused `C +=` CSR.** K-split accumulate is a core integer add after a scratch GEMM.
- **No fill/compute overlap.** Ping-pong RAMs exist; the FSM does not prefetch the next K tile during MAC.
- **No PD timing closure** on the GEMM DMA path.
- **No host random-matrix suite on the card** with the same seeds as XSim (nice, not blocking).
- **Not a GPU.** Tensors are compile-time static buffers. The runtime sees flat int32 vectors plus a GEMM job. Rank lives in generated loops.

The hardware contract is frozen for this pass. Bigger problems are a compiler problem.

---

## How to poke it

```bash
# SoC: ISS vs RTL, including PyVedas GEMM
make smoke
# or: python3 tools/sim_manager.py --test-list tests/gemm.tlist

# Standalone gemm_top
make gemm-directed
make gemm-cosim

# Planner lockstep (no sim)
python3 -m unittest tests.unit.test_gemm_tiles tests.unit.test_gemm_codegen

# Card (bitstream already programmed)
make fpga_smoke alveo_u280
```

A 128×128 PyTorch spec is [`tests/pyvedas/gemm_mmio_128.py`](tests/pyvedas/gemm_mmio_128.py): `gemm_mmio(A, I)` with a small integer A. The JIT emits one START. Hardware walks 16×16 output tiles and four K=32 panels. That is the point.

---

## Talking points (steal these)

### One sentence

We took an 8×8 int8 GEMM from SystemVerilog to PyTorch, to a RISC-V ELF, to an Alveo U280, and to ASAP7 GDS — and the compiler tiles against on-chip SRAM, not against the PE array.

### LinkedIn (long)

Most accelerator write-ups show a systolic array in a testbench. We wanted the boring parts that make it real.

Tiny Vedas now has an 8×8 output-stationary int8 GEMM sitting next to an RV32IM core, sharing DCCM over packed AXI4 bursts. One MMIO START is one 2-D matmul. The hardware already walks 8×8 / K=32 tiles, including remainders.

The compiler lesson: do not emit an 8×8 nest for a 128×128 that still fits on-chip. Hardware micro-tiles one job. PyVedas only splits when the problem (or its pack scratch) does not fit DCCM, or when you have a batch. K-splits accumulate in software because the engine overwrites C. Rank > 2 is a loop of 2-D GEMMs with `torch.matmul` broadcast.

Same ELF family runs in the ISS, in XSim, and on an Alveo U280. The CPU+GEMM pair also went through OpenROAD on ASAP7. In the routed plot the array is ~6× the core.

Apache-2.0. Stack: RISC-V, SystemVerilog, PyTorch, FPGA, open PD.

### X / Twitter (thread)

1/ We built a real GEMM for a tiny RISC-V SoC: 8×8 int8×int8→int32, packed AXI DMA into DCCM, programmed by MMIO from the core (and from a PyTorch JIT).

2/ Two tiling problems. Hardware already tiles one START (8×8, K=32). The compiler tiles against SRAM and batch rank. Mixing them up means your JIT re-implements the PE array.

3/ 128×128 that fits DCCM = one START. 512×8×257 (bigger than the old 256² pack) = software K-panels + add. `bmm` = a for-loop of 2-D GEMMs.

4/ Same tests: ISS, XSim, Alveo U280 smoke, ASAP7 GDS of CPU+GEMM. Array area ~20.4 kµm² vs core ~3.5 kµm². Timing closure still on the TODO list — DMA address math is the long pole.

5/ Open source (Apache 2.0). Tiny Vedas: from `torch.compile` to a systolic array without a CUDA runtime in the middle.

### Reddit (r/RISCV, r/FPGA, r/hardware)

**Title:** 8×8 int8 GEMM on an RV32IM core: PyTorch JIT, Alveo U280, ASAP7 GDS

We added an MMIO GEMM to Tiny Vedas (open RV32IM stack). Short version of the contract:

- Output-stationary 8×8, int8 MAC, int32 acc, K-tile 32
- Dual AXI4 master DMA, packed 32-bit INCR, A/B/C in DCCM
- Core stalls on `accel_hold` for the job — firmware does not poll DONE before reading C
- Hardware walks M→N→K including remainders; one START = one overwrite 2-D GEMM

Compiler (PyVedas) does *memory* tiling: pack scratch is per hardware-facing tile (128 KiB cap on 1 MiB DCCM), not a 256² whole-matrix buffer. Rank ≥ 2 with broadcast batch. K-split C accumulation is integer add in the core (no accumulate CSR yet).

Verified: Python ISS vs RTL, directed/random `gemm_top` cosim, multi-job C test that would catch stale ping/`k_tile`/`clear_acc`, FPGA ELF smoke, `core_gemm_top` through OpenROAD.

Not claiming Fmax glory (≈1.05 GHz on this drop) or fill/compute overlap (RAMs are ping-pong, FSM is not). Happy to argue about whether software K-accumulate is the right MVP vs a C+= bit.

---

## File map

| Path | Role |
|------|------|
| `rtl/accel/gemm_*.sv` | CSR, DMA, PE, datapath, job FSM |
| `rtl/include/gemm_csrs.svh` | Offsets, PE dim, K-tile, mul pipe drain |
| `pd/rtl/core_gemm_top.sv` | PD wrapper (CPU + GEMM) |
| `fpga/alveo_u280/` | SoC mux, ILA, host load |
| `pyvedas/gemm_op.py` | `torch` custom op |
| `pyvedas/jit/memory/gemm_tiles.py` | Fit-or-tile planner |
| `pyvedas/jit/codegen_handlers.py` | Emitted loops |
| `pyvedas/runtime/c/gemm_mmio.c` | Pack / START / scatter-add |
| `tools/rv_iss.py`, `tools/gemm_ref.py` | Functional START |
| `tools/gemm_cosim.py` | Directed / random / perf |
| `tests/gemm.tlist` | GEMM regression list |
