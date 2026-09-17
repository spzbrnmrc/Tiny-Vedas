Next work on top of GEMM MVP (document only — do not implement from this file)

**Status:** Days 1–3 GEMM MVP is done (RTL + ISS + XSim + ASAP7 `core_gemm_top`
GDS + Alveo Booth bitstream, `tests/smoke.tlist` 32/32 on card including
`asm.gemm_8x8` / `c.gemm_8x8` / `pyvedas.gemm_mmio`). This file is only
queued work: compiler tiling, then DMA.

---

## Reasoning

There are two different “tiling” problems. Mixing them up will produce a
compiler that re-implements the PE array in software.

**Hardware already micro-tiles one 2-D job.** The array is 8×8 OS, K-tile 32.
`gemm_top` walks M, then N, then K and DMA’s tiles from DCCM. One CSR START
with `(M,N,K)` can be 32 / 128 / 256 as long as A, B, and C live in DCCM.
PyVedas must not emit an 8×8 nest for a 128×128 that already fits.

**PyVedas does not compiler-tile.** Codegen requires rank-2 A/B and emits a
single `pyvedas_gemm_mmio(A, B, C, M, N, K)`. The runtime packs the whole A/B
into static `256×256` int8 scratch and hangs if that overflows. Rank > 2 is a
hard JIT error. So:

1. **Matmul larger than the PE array, still 2-D, fits DCCM** — already works.
   Hardware tiles. Leave it alone.
2. **Matmul (or its packed A/B/C) does not fit DCCM / the pack scratch** —
   one START cannot represent the op. The compiler (or a small runtime
   helper) must split into several GEMM jobs whose footprints fit, and
   accumulate C across K-splits.
3. **n > 2 (batch, `bmm`, leading dims)** — not a bigger systolic array; it
   is a loop of 2-D GEMMs over the batch (each slice may still need (2)).

The compiler’s job is **problem tiling against on-chip memory and rank**, not
re-tiling against `GEMM_PE_DIM`. Tile size for (2) should be the largest
`(m_t, n_t, k_t)` that fits DCCM given the live int32 A/B/C buffers plus
int8 pack scratch — typically a multiple of 8×8 / K=32 so the hardware
path stays dense, with the existing zero-pad path covering remainders.

K-split is the subtle one: each K-panel is a full GEMM into a temp (or
into C with an accumulate mode we do not have yet). MVP hardware is
**C = A @ B overwrite**. Software K-tiles must either (a) GEMM into a
scratch C tile and add in the core, or (b) add a later CSR accumulate
bit. Prefer (a) first — no RTL change.

Batch / n-D: numpy/`torch.matmul` rules (broadcast batch dims, last two
are M,K × K,N). Emit `for` over the linearized batch, each iteration a
2-D GEMM (possibly itself memory-tiled). Do not require the Python op to
be already squeezed to 2-D.

---

**Locked decisions:**
- Hardware contract unchanged: one START = one 2-D int8×int8→int32 GEMM,
  overwrite C, DCCM-resident pointers. No new CSRs for compiler tiling.
- Compiler tiling lives in PyVedas (codegen and/or `pyvedas_gemm_mmio`
  runtime), not in `gemm_top`.
- Do not emit software tiles smaller than the PE/K hardware tile unless
  the remainder is smaller.
- Rank-2 that fits DCCM + pack scratch: still one START (today’s path).
- Rank-2 that does not fit: loop M/N output tiles and K panels; K panels
  accumulate in software onto int32 C.
- Rank > 2: batch loop of rank-2 GEMMs; reuse the same fit-or-tile helper.
- Pack scratch stays DCCM-static but sized to **one hardware-facing tile**,
  not the full problem (kills the 256² whole-matrix cap).
- ISS already applies a full matmul on one START; multi-START sequences
  must match ISS vs RTL the same way as any other MMIO program.

**Day 4 — Fit check + rank-2 memory tiling**

Deliverables:
- Shared helper: given `(M,N,K)` and DCCM budget, either “one shot” or a
  list of `(m0,n0,k0,m_t,n_t,k_t)` jobs.
- `pyvedas_gemm_mmio` uses that helper; pack buffers are per-tile, not
  whole-matrix. Hang-on-overflow goes away for tiled cases.
- Codegen still emits one call; the runtime loop is fine for MVP of this
  day (no unrolled START soup in `generated.c` yet).
- Tests: 2-D that still one-shots (8, 32, 128); 2-D larger than pack/DCCM
  budget (force a small budget in unit tests, plus a real size that
  exceeds 256² pack, e.g. 512 if DCCM allows C but not the old scratch).

Gate: XSim ISS-vs-RTL on one-shot and multi-job 2-D cases; C matches
`int8` golden. FPGA ELF smoke for at least one multi-job 2-D.

**Day 5 — n > 2 / batch**

Deliverables:
- JIT accepts A/B with rank ≥ 2; last two dims are the matmul, leading
  dims are batch (broadcast per `torch.matmul`).
- Codegen emits batch loop + call into the Day 4 helper per slice
  (or one runtime entry `pyvedas_gemm_mmio_nd` that takes ranks/shapes).
- Tests: `bmm` 4×8×8, broadcast batch `(3,1,8,8)@(8,8)`, 3-D where each
  slice also memory-tiles.

Gate: XSim ISS-vs-RTL + Alveo EOT self-check against baked goldens.

**Not this pass (tiling):**
- CSR accumulate / fused C+= — only if software add on K-panels shows up
  as the bottleneck.
- Dual-buffer DMA vs compute overlap inside `gemm_top` (RTL already
  ping-pongs buffers but the scheduler is still fill-then-compute). See
  DMA section below.
- ILA dump of a 128³ wave; host random-matrix suite on the card (same
  seeds as XSim). Nice, not blocking tiling.

---

## GEMM DMA (after tiling, not now)

Jobs are **DMA-bound**. The 8×8 Booth array is not the FPGA timing or
runtime limit. Routed Alveo `clk_out1` (100 MHz, 10 ns) closed with
**1.407 ns WNS**; the worst path is `gemm_dma` C-address
(`c_r` → unpipelined DSP `row*N+col` → DCCM `EN`), not a PE. The 64
`WIDTH=8` muls do not appear in the worst-path dump. Whole-chip util is
~7% LUT / 9 DSP48s (those DSPs *are* the DMA address generators).

What the engine actually does today (`rtl/accel/gemm_dma.sv`):

- **One 32-bit beat per element.** `arlen=0` / `awlen=0`. A and B are
  int8, so each PE lane is a word read plus `extract_byte` — 4× bandwidth
  waste, and unaligned bases work by accident.
- **One outstanding AR per port.** `a_ar_pend` / `b_ar_pend` block the
  next address until RDATA. DCCM latency is paid in series.
- **Combinational 32-bit `base + row*stride + col`** on the AR/AW path
  (A/B byte, C `*4`). That is the 100 MHz critical path and the Yosys
  area hog. Incremental addressing would drop the DSPs.
- **Port0 is A-read *or* C-write, port1 is B-read only.** Cannot fetch
  next A while retiring C without a mux/port change.
- **`gemm_top` is fill → compute → store.** `a_buf[2]`/`b_buf[2]` exist
  and `ping` flips, but `G_FILL` waits `done_ab` before `G_COMPUTE`, and
  `G_STORE` waits `done_c` before the next fill. Dual-buffer is wiring,
  not overlap.

Do **not** start with a wider DCCM or a third AXI master. The cheap
wins are address math and using the 32-bit bus we already have.

**Locked decisions (when we pick this up):**
- Hardware contract stays one START = one 2-D DCCM GEMM. DMA is an
  internal engine; no new CSRs required for burst/pack.
- Keep 32-bit AXI into DCCM for this pass. Wider SRAM is a PD/FPGA
  memory-compiler change, not a DMA FSM tweak.
- Dense path may require **4-byte aligned** `BASE_A/B/C` and K/N
  multiples of 4; remainder tiles already zero-pad unused PE lanes —
  pack/unpack there, do not keep per-byte AR forever.
- Address generation is incremental (`row_base + 1` / `+4`), not a
  fresh multiply every beat. Optional flopped formula is a fallback if
  incremental is ugly on remainders.
- Burst along the contiguous dim: A row is K-contiguous int8 (K-tile
  32 → 8 beats of 4 packed bytes); B along N; C already int32 along N
  (`AWLEN` for the n-tile). Cross-row = new burst (2-D is not INCR).
- Allow a small outstanding window (at least 2–4, or ARLEN beats)
  so DCCM hit latency hides. Still one in-flight *burst* per port is
  fine if LEN > 0.
- Overlap only after bursts work: fill buffer `1-ping` while the array
  runs on `ping`; issue C-store of the previous tile when port0 is
  free. If A-fetch and C-store fight on port0, move C writes to port1
  after B is in the buffer (port1 is idle in `D_C` today) — do not add
  a third master yet.
- Gate: directed 8×8×32 / 8×8×8 still PASS vs ISS; FPGA core WNS stays
  ≥ 0 on `clk_out1`; a cycle count or `perf` dump shows fill+store
  dropping vs today’s 1-beat-per-element.

**Day 6 — Address + burst (timing + bandwidth)**

- Incremental A/B/C pointers; kill the beat-wise `*` on the AXI
  command path (this is also the FPGA 100 MHz critical path).
- Pack 4 int8 per beat; `ARLEN`/`AWLEN` along the contiguous tile dim.
- Tests: existing GEMM directed + unaligned/remainder tiles still
  match golden (or explicitly trap unaligned if we lock the align
  rule). Compare XSim cycle count vs MVP on 8×8×32.

**Day 7 — Outstanding + fill/compute overlap**

- `gemm_top`: next `start_ab` into `1-ping` during `G_COMPUTE`;
  `start_c` of the finished tile without waiting for the next fill
  (port1 C-write if port0 is fetching A).
- FPGA: confirm WNS does not regress; smoke still 32/32.

**Not this pass (DMA):**
- 128-bit/256-bit DCCM, 2-D AXI, cache, prefetch from host DDR.
- Software-visible stride CSRs (row-major DCCM is the MVP layout).
- Retuning Booth pipe / PE array for FPGA Fmax — it is not the limit.
