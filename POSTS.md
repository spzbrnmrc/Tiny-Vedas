# LinkedIn posts — Tiny-Vedas / Siliscale consultancy

Ready to paste. Facts only. Do not invent metrics. Do not claim I beat Arm.
CTA on every post: **marco@siliscale.com**

**Images**

| Post | File |
|------|------|
| 1 | `pd/work/layout/annotated_core_gemm.png` (or the routed sibling) |
| 2 | helloworld UART before/after, or a short card-smoke terminal crop |
| 3 | the two-tiling diagram from the GEMM note, or a 3-box sketch |
| 4 | same die shot as 1, cropped |

**Locked numbers**

- ASAP7 `core_gemm_top` (memories as IOs): core **3,462 µm²** / 29,364 cells; GEMM **20,386 µm²** / 176,050 cells
- Alveo U280, 100 MHz core, bitstream WNS **1.176 ns**
- FPGA `smoke.tlist`: **100 consecutive runs, 37/37 every time**
- Dhrystone on card: ~**12.9 ms** / 2000 runs → ~**88.5 DMIPS** / **~0.89 DMIPS/MHz** (host EOT). Cortex-M0 *neighborhood*, not a bake-off.
- UART bug: got `Hello, World!\n\nNumber is100\n`, wanted `Hello, World!\nNumber is 100\n`. Dhrystone characters doubled. XSim did not see it.

---

## 1 — Receipt

Same RV32 core and 8×8 int8 GEMM on an ASAP7 GDS and on an Alveo U280.

The plot is `core_gemm_top` after OpenROAD. Gold is the CPU: 3,462 µm². Cyan is the matrix engine: 20,386 µm². The accelerator is the chip. The core is the programmer.

That is the point of Tiny-Vedas. Not a PE array in a testbench.

- `torch.compile` emits a bare-metal ELF
- one MMIO START is one 2-D GEMM in DCCM
- hardware already walks 8×8 tiles and K=32
- the compiler only splits when the *problem* does not fit on-chip memory, or when rank > 2
- host loads the ELF over PCIe. One bitstream. Same smoke list as sim.

I then ran that smoke list on the card 100 times in a row. 37/37 every time.

If you have an array in a TB and you need PyTorch on a card — or a GDS that is the same design, not a cousin — that is the work I do.

marco@siliscale.com

Tiny-Vedas is open (Apache-2.0). The course is free: https://youtu.be/izPdo7n1uI

#RISCV #FPGA #ASIC #PyTorch #OpenROAD

---

## 2 — Pain

XSim said helloworld was fine. The Alveo card printed this:

Hello, World!

Number is100

The space before 100 was gone. Dhrystone’s UART was every character twice. The test still “passed” if you only looked at EOT.

The mailbox sampled the LSU store as a level. `dc2_store_v` can stay high across a stall. When the AXI CDC ack came back while the same `sw` was still asserted, I captured the byte again and dropped the next one.

A software delay cannot fix that. One stalled store is still one store.

I edge-detect the MMIO write, queue 64 bytes, let the 100 MHz / ~250 MHz CDC drain, rebuilt the bit (core WNS 1.176 ns). Then:

100 consecutive FPGA smoke runs. 37/37. UART golden exact, every time.

This is the class of bug that never shows up if your “FPGA story” is a testbench plus a hope. Sim and the card are not the same path.

If your bring-up still dies in the gap between ISS, RTL, and the card, that is a consultancy problem, not a weekend problem.

marco@siliscale.com

#FPGA #Verification #RISCV #Alveo

---

## 3 — Insight

There are two tiling problems. Mixing them up produces a compiler that re-implements your PE array in software.

Hardware already micro-tiles one job. Mine is 8×8 output-stationary, int8×int8→int32, K-tile 32. One CSR START with (M, N, K) can be 32 or 128 as long as A, B, and C live in DCCM. The engine walks M, then N, then K. Remainders are zeros, not a special software path.

The compiler tiles against **on-chip memory and rank**, not against the PE dimension.

1. Rank-2, fits DCCM + pack scratch → one START. Leave it alone.
2. Does not fit → loop M/N output tiles and K panels. Hardware overwrites C, so K panels add in the core. No new CSR.
3. Batch / bmm / leading dims → a loop of 2-D GEMMs (torch.matmul broadcast). Each slice may still need (2).

I moved that planner into the JIT. The runtime is one planned job: pack, START, scatter. The RV core does not decide how many STARTs at runtime.

If your software team is emitting an 8×8 nest around a 128×128 that already fits, you hired a compiler for the wrong layer.

That split — hardware tile vs memory tile — is the design. It is also the thing most accelerator programs get backwards.

marco@siliscale.com

#Compilers #PyTorch #RISCV #Hardware

---

## 4 — Offer

Siliscale is a consultancy. Tiny-Vedas is the public receipt.

I take an AI accelerator from “RTL in a testbench” to “PyTorch job on a card, same tests as sim.” Sometimes through GDS.

Three paid shapes:

1. **Bring-up** — PCIe/QDMA, halt-and-load, UART/EOT, the bugs that only exist on the card.
2. **Compiler** — `torch.compile` (or your graph) → bare-metal, tiled against *your* SRAM, not a generic PE loop.
3. **Lockstep** — ISS vs RTL vs FPGA. If the three disagree, that is the work.

Tiny-Vedas is Apache-2.0: RV32IM core, 8×8 int8 GEMM, Alveo U280 path, ASAP7 `core_gemm_top`. Use it, fork it, do not send me patches — if you want me on *your* IP, email.

Course (free): https://youtu.be/izPdo7n1uI
Repo: https://github.com/siliscale/Tiny-Vedas

Book a call: marco@siliscale.com

#Consulting #RISCV #ASIC #FPGA #AIHardware
