Next work on top of GEMM MVP (document only — do not implement from this file)

**Status:** GEMM MVP + DMA packed-INCR rewrite are done (RTL + ISS + XSim +
ASAP7 `core_gemm_top` GDS + Alveo bitstream). Card smoke includes
`asm.gemm_8x8` / `c.gemm_8x8` / `c.gemm_multi` / `pyvedas.gemm_mmio`.
This file is queued **compiler tiling** only. Timing closure is not on
the agenda. Fill/compute DMA overlap is leftover RTL, not this pass.

---

## Hardware contract (do not change for tiling)

- One START = one 2-D int8×int8→int32 GEMM, overwrite C, DCCM-resident
  pointers. No new CSRs.
- Array is 8×8 OS, K-tile 32. `gemm_top` walks M, then N, then K.
- DMA is packed 32-bit AXI4 INCR (A along K, B along N, C int32 along N),
  incremental addresses, one outstanding burst per port. Remainders unpack
  in the engine.
- Wait is core `accel_hold` for the job. Software must **not** poll STATUS
  before reading C. DONE is sticky until the next START; START re-inits
  tile indices / ping / accumulators. CSRs persist; A/B/C buffers are not
  wiped on DONE.
- Multi-job in one ELF is already required (`tests/c/gemm_multi.c`).
- FPGA halt between host tests resets core + GEMM + DCCM AXI slave
  (`core_rstn`). That is a host-load concern, not a compiler concern.

---

## Reasoning

There are two different “tiling” problems. Mixing them up will produce a
compiler that re-implements the PE array in software.

**Hardware already micro-tiles one 2-D job.** One CSR START with `(M,N,K)`
can be 32 / 128 / 256 as long as A, B, and C live in DCCM. PyVedas must
not emit an 8×8 nest for a 128×128 that already fits.

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
into C with an accumulate mode we do not have yet). Hardware is
**C = A @ B overwrite**. Software K-tiles must either (a) GEMM into a
scratch C tile and add in the core, or (b) add a later CSR accumulate
bit. Prefer (a) first — no RTL change.

Batch / n-D: numpy/`torch.matmul` rules (broadcast batch dims, last two
are M,K × K,N). Emit `for` over the linearized batch, each iteration a
2-D GEMM (possibly itself memory-tiled). Do not require the Python op to
be already squeezed to 2-D.

---

**Locked decisions:**
- Hardware contract unchanged (see above). Compiler tiling lives in
  PyVedas (codegen and/or `pyvedas_gemm_mmio` runtime), not in `gemm_top`.
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

**Not this pass:**
- CSR accumulate / fused C+= — only if software add on K-panels shows up
  as the bottleneck.
- Fill/compute overlap inside `gemm_top` (`a_buf`/`b_buf` ping-pong is
  wired; the scheduler is still fill → compute → store). Leftover RTL
  for a later DMA pass.
- PD timing closure (Fmax ~1.05 GHz on DMA `csr_n` → `awaddr`).
- ILA dump of a 128³ wave; host random-matrix suite on the card (same
  seeds as XSim). Nice, not blocking tiling.
