# Tiny-Vedas Alveo U280 FPGA bring-up — session handoff

**Audience:** draft a LinkedIn post (technical but accessible).  
**Product:** Tiny-Vedas — open-source RV32IM CPU (Siliscale).  
**Board:** Xilinx Alveo U280 (PCIe accelerator).  
**Branch:** `fpga`  
**Date context:** September 2026.

This note summarizes the full FPGA bring-up arc culminating in Slice C smoke on hardware. Use facts below; do not invent metrics.

---

## One-line story

We brought Tiny-Vedas up on an Alveo U280 over PCIe: one bitstream, host loads programs at runtime, full smoke regression (including Dhrystone) passes on the card — same tests as simulation.

---

## Why it matters

- Tiny-Vedas was sim/ASIC-oriented; this closes the loop with **real silicon on a datacenter FPGA**.
- **One bitstream**, many programs: no rebuild-per-test. Host loads ICCM/DCCM over PCIe, runs, polls EOT, checks UART goldens where defined.
- Same memory model and smoke list as RTL sim → fewer “works in sim, dies on FPGA” surprises.
- Concrete performance: **~89 DMIPS** at **100 MHz core** ≈ **~0.9 DMIPS/MHz** (host-timed EOT) — same *efficiency neighborhood* as Cortex-M0 class cores (~0.9), not a “beat Arm” claim.

---

## Delivery model (Slices A → B → C)

| Slice | What | Outcome |
|-------|------|---------|
| **A** | QDMA PCIe shell, CTRL regs, host R/W BRAM | Prove BAR access, VERSION/HEARTBEAT/SCRATCH |
| **B** | Glue Tiny-Vedas core + UART mailbox + EOT | Run real RV32 code from host-loaded memories |
| **C** | `fpga_runner` over `tests/smoke.tlist` | Full regression on card, same list as `make smoke` |

**Final FPGA map (B16):** BAR2 **128 KiB** — CTRL 4 KiB + **ICCM 32 KiB** + **DCCM 64 KiB**. VERSION `0x000B0010`.

---

## Hard problems we hit (good LinkedIn texture)

### 0. Host OS ↔ QDMA driver
Stock Xilinx `dma_ip_drivers` **2023.2.1** does not build cleanly on **Linux 6.8 / Ubuntu 24.04**. We keep a small out-of-tree patch:

- `fpga/alveo_u280/patches/qdma-2023.2.1-linux-6.8.patch`
- apply via `fpga/alveo_u280/scripts/patch_qdma_driver.sh`

Mostly **kernel API shims** (`iov_iter` / `class_create` / PCI domain bits) — not custom DMA engine logic. After program, `program_fpga.py` unload/reload `qdma-pf` so BAR2 mmap works. Host load path is BAR mmap more than H2C streaming, but the PF driver still has to bind.

---

Early FPGA debug used retire TRACE into the host. Backpressure / stalls into the pipe caused **hangs or corruption**. Combo stall, registered stall, FIFO/CDC experiments all fought the core.

**Resolution:** drop FPGA TRACE for bring-up. FPGA pass criterion = **EOT** (+ UART golden for some tests). Sim keeps ISS vs RTL compare under `!SYNTHESIS`. Lesson: observability must not become a second CPU.

### 2. Host load reliability
Large ICCM loads via bulk mmap / posted PCIe writes could **truncate** images → mysterious hangs (looked like core bugs).

**Resolution:** synced word `write_bytes` on the host path; verify VERSION; halt core while loading.

### 3. Fitting Dhrystone
Needed **64 KiB DCCM** (and 128 KiB BAR). With that, `elf.dhrystone` runs on card.

### 4. Self-checking software
Without TRACE compare on FPGA, tests must **fail closed**: check-then-EOT, hang-on-fail canaries (`fail_hang.s`), PyVedas goldens baked then compared before EOT. Dual-EOT zombies → hang (good).

### 5. Printf / LSU footgun
UART putc used RISC-V **`sb`**. LSU does **RMW** on byte/half stores → pipeline busy stalls on every printf character → helloworld cycles/IPC looked awful vs old README numbers.

**Resolution:** UART putc uses aligned **`sw`** (MMIO only samples `wdata[7:0]`). Documented in `vedas_printf.c` so the next agent does not “fix” it back to `sb`. Absolute cycles improved; IPC can still drop when you delete easy filler instructions (ratio ≠ speed).

---

## Validation (call these out)

**Simulation:** `make smoke` / `make smoke-verilator` — full `tests/smoke.tlist`.

**FPGA (final session run):** **29/29 PASS**, 0 failed, 0 skipped  
- Includes asm suite, `c.helloworld` (UART golden), `c.iaxpy`, PyVedas kernels, **`elf.dhrystone`**  
- Dhrystone on card: ~**12.8 ms** EOT for 2000 runs → ~**156k dps / ~88.9 DMIPS** (host wall clock) at **100 MHz** → **~0.89 DMIPS/MHz**
- Cross-check: sim ~1.27 M cycles ≈ 12.7 ms @ 100 MHz — matches FPGA wall time

**Developer UX:**
```bash
make fpga alveo_u280          # build bitstream
make fpga_smoke alveo_u280    # PCIe smoke (sudo + programmed card)
```

---

## Sim performance scoreboard (updated this session)

From RTL sim `work/<test>/stats.txt`:

| Benchmark | Instructions | Cycles | IPC |
|-----------|-------------:|-------:|----:|
| c.helloworld | 760 | 2293 | 0.3314 |
| c.iaxpy | 109 | 235 | 0.4638 |
| elf.dhrystone | 640720 | 1274337 | 0.5028 |

Note: older README helloworld IPC (~0.62) was a different printf/binary mix (asm-era). Current numbers reflect C `vedas_printf` + UART `sw`. Prefer **cycles** or DMIPS for “are we faster,” not IPC alone when the instruction mix changes.

---

## Architecture snapshot (for technical readers)

- Core: Tiny-Vedas RV32IM on QDMA `axi_aclk` domain with MMCM lock gating.
- Memories: shared synthesizable sync TDP ICCM/DCCM (`rtl/lib/mem_lib.sv`), host-writable while core halted.
- Host: Python BAR2 mmap (`vedas_host.py`), ELF → ICCM `.text` / DCCM data, reset vector, run, EOT, UART FIFO.
- No retire TRACE on FPGA path; sim retains debug under non-synthesis.

---

## Key commits on `fpga` (recent)

- `674a970` — Alveo U280 FPGA path + synthesizable ICCM  
- `72d47e2` — Smoke runner + shared sync TDP memories  
- `357124f` — B16: EOT self-check smoke, 64 KiB DCCM, no FPGA TRACE  
- `3928e18` — UART word stores + refreshed sim scoreboard  
- `54b5b4b` — Document why putc uses `sw` not `sb`  
- *(plus)* `make fpga_smoke <board>` target and README wiring  

---

## Suggested LinkedIn angles (pick one spine)

1. **Bring-up narrative:** sim → PCIe shell → first UART → full smoke on Alveo.  
2. **Engineering honesty:** TRACE that hangs the core; PCIe posted-write truncation; byte-store RMW tax.  
3. **Outcome metric:** same smoke list on FPGA + ~0.9 DMIPS/MHz (M0-class efficiency neighborhood) on a research RV32 core.  
4. **Open tooling:** one bitstream, host load, `make fpga_smoke`.

Tone: proud but concrete; avoid “world’s first” claims; Siliscale / Tiny-Vedas / Alveo U280 / RISC-V are the name-checks.

---

## What this is *not* (avoid overclaiming)

- Not an XRT/Vitis shell product launch.  
- Not superscalar/VLIW FPGA results (those are roadmap elsewhere).  
- Not claiming FPGA IPC matches the old 0.6177 helloworld number.  
- TRACE-quality on-hardware debug is still a follow-on, deliberately deferred.
- **Do not** claim we beat Arm / Cortex-M*. Safe line: “~0.9 DMIPS/MHz — in the Cortex-M0 efficiency neighborhood,” with host-EOT / non-ProcTime caveat.

---

## Handy quotes / phrases

- “One bitstream. Host loads the ELF. Same smoke list as simulation.”  
- “If your debug channel can stall the pipeline, it isn’t debug — it’s a second CPU.”  
- “Byte stores to UART looked innocent until LSU RMW showed up in the CPI.”  
- “29/29 on Alveo, including Dhrystone at ~90 DMIPS / ~0.9 DMIPS/MHz (100 MHz core).”
- “Efficiency in the Cortex-M0 neighborhood — not an Arm bake-off.”
