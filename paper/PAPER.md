# Paper plan

Compiler paper. The JIT tiles a detector against on-chip memory and
**places** those tiles on two clusters. The SoC is the backend.
Do not invent metrics. Visible draft is `content/`; status and gates
live in comments there.

**Title:** *From `torch.compile` to Two Clusters: Placing Detection
Tiles on a Tiny GPU*

**Reader takeaway:** `torch.compile` placed the tiles.

**How we build:** YOLO ops first, then RVV, then the JIT, then a
single-core run, then a **modular requant pass** so the integer
board score is a detector. L2 / HBM, the second core, and the job
scheduler come after that. We do not design the memory hierarchy
or the scheduler before we know the graph.

**Publish:** arXiv when single-core YOLO runs on the U280 **and**
the integer / card mAP is the post-requant number (Step 5), not
the 0.002 first-design requant. ASPLOS / MLSys after the
scheduler places tiles on two clusters and a second net exists.
HPCA / MICRO / ISCA only if L2/HBM/2-cluster logs plus power/area
are the sentence people quote.

Tiny (~8.7 M weights) does not fit DCCM. Single-core YOLO therefore
streams layers through on-chip memory (208 allowed to get a
number; **416 is what we report**). HBM is how that becomes a
real working set, not the first RTL drop.

---

## Done

### RTL / SoC

- [x] RV32IM 4-stage core (IFU / IDU / EXU / LSU)
- [x] 8×8 output-stationary GEMM (int8×int8→int32, K-tile 32)
- [x] GEMM packed AXI4 DMA + CSRs at `0x00300000`
- [x] AXI4 ICCM / DCCM, MMIO mux (UART, GEMM, EOT)
- [x] Alveo U280 overlay, halt-and-load, VERSION `0x000B0014`
- [x] UART edge-sample + 64-deep TXQ

### Software / verify / PD

- [x] PyVedas: `torch.export` → C → RV32 ELF
- [x] GEMM planner vs DCCM / rank; C overwrite; software K-add
- [x] Rank > 2 as a batch loop of 2-D GEMMs
- [x] ISS / Verilator lockstep (`sim_manager`)
- [x] FPGA smoke 100× 37/37; zve32x overlay 45/45
- [x] ASAP7 `core_gemm_top` GDS
- [x] Paper LaTeX (arXiv / ASPLOS’27 / MLSys’27)

### Locked numbers (do not invent siblings)

- [x] `core_gemm_top`: core 3,462 µm² / 29,364 cells; GEMM
      20,386 µm² / 176,050 cells
- [x] U280 100 MHz, WNS 0.483 ns (zve32x overlay)
- [x] Dhrystone ~88.5 DMIPS / ~0.89 DMIPS/MHz (host EOT)
- [x] Host mAP@0.5 int8 YOLOv3-Tiny 416, coco128 n=16: 0.3469
      (`python -m models.yolov3_tiny eval --limit 16 --size 416`)
- [x] Host mAP@0.5 int32 `--cal work/requant_cal.yaml`, coco128
      n=16: **0.274089** (208) / **0.332537** (416). Not 0.3469
- [x] Card mAP@0.5 int32 YOLOv3-Tiny 208, coco128 n=16: **0.274089**
      at **80 MHz** (`eval_n16.log`). Same 192 boxes on
      `000000000009.jpg` for every nest (same MACs). Fastest
      honest nest is `cache_col`: **295907.7 ms/frame**
      (`eval_n1_cachecol.log`). Ranked on host `-O0` generated C,
      then the card. Not `oc`-outer (395472.2 ms, 1536 `im2col`).
      Not spatial-outer (315857.6 ms, 1536 packs)

---

## 1 — YOLO graph (what the JIT must lower)

Get the model. The op list drives RVV and the JIT. Do not invent
ops we do not see.

- [x] int8 YOLOv3-Tiny in PyTorch (exportable graph, 208 and 416)
- [x] Walk `torch.export`: every `call_function` named
- [x] Confirm at least: conv2d, leaky ReLU, max-pool
- [x] Rest of the list: upsample, concat, letterbox, box decode;
      NMS is host-side (does not export)
- [x] Golden: host mAP > 0 on the same weights we will ship

---

## 2 — RTL drop: RVV 1.0

Vector first. ReLU and max-pool will live here. Conv stays a
separate engine (or im2col+GEMM) once we see the graph.

**Locked before RTL** (ISA / bring-up, not the full spec):

| Item | Lock |
|------|------|
| Profile | RVV 1.0 **Zve32x** only. No V-F, no Zve32f, no Zvl* beyond 512. |
| VLEN | **512** bits (SV parameter). 16×i32 at LMUL=1. |
| LMUL | **1** only. Other `vlmul` → `vill`. No fractional LMUL. |
| SEW | **32 only** for v1. SEW 8/16 → `vill`. YOLO C is int32. |
| Tail / mask | **Agnostic only** (`vta=1`, `vma=1`). No undisturbed tails. |
| `vstart` | Always **0**. Do not resume mid-vector. |
| Memory | **Unit-stride** `vle32.v` / `vse32.v` only. No strided, indexed, segment, whole-reg, first-fault. |
| Permute | None: no slide, gather, zip, reduction. |
| Widening | None (`vwmul`, `vwaddu`, …). |
| `vset*` | `vsetvli`, `vsetvl`, `vsetivli`. Reset: `vill=1`, `vl=0`. CSRs: `vl`, `vtype`, `vlenb`. No `vxsat` / `vxrm`. |
| ALU v1 | `.vv` and `.vx`: add/sub, and/or/xor, min/max (s+u), shifts, compares; `vmv.v.{v,x,i}`. Masked via `v0` if GCC asks. |
| Align | EEW-aligned only. |
| Traps | No new trap stack (ECALL is still a NOP). Bad `vtype` → `vill`. Undecodeable vector → test fail, same as an unknown scalar op. |
| Datapath | **128-bit** execute slice × 4 beats (SV parameter). Not 512 ALUs in one cycle. |
| Toolchain | `-march=rv32im_zve32x -mabi=ilp32 -mrvv-max-lmul=m1`. Write flat int32 loops. |
| Decode | Vector rows in `open-decode-tables`, then `make decodes`. |
| Verify | ISS and RTL same subset, lockstep from the first `vsetvl`. |

GCC still picks the exact integer opcodes inside that box. If it emits strided or SEW=8, change the C, do not grow the ISA on day one.

YOLO channels are 16, 32, 64, 128, 256, 384, 512, 1024, and 255
(detect). VLEN=512 / SEW=32 → VL=16; strip-mine. 255 has a tail.

- [x] Zve32x: CSRs, vreg file, VLEN-parameter datapath (default 512)
- [x] Decode + issue in the existing pipeline
- [x] ISS RVV, lockstep vs RTL
- [x] FPGA + smoke (`vsetvl` + a min/max or add kernel)
- [x] `hw/` preset: vector on, `width_bits: 512`, matches this RTL

CI `smoke-verilator` and `make smoke` default to `rv32im_zve32x`,
so `asm.rvv_*` and the RVV PyVedas kernels run. Scalar is
`HW_CONFIG=hw/presets/rv32im_scalar.yaml`.

---

## 3 — JIT: YOLO ops

Extend PyVedas so the exported graph is legal. One graph op, one
registry entry, one kernel (vector where §2 exists).

The JIT graph is the **integer** module (`YoloV3TinyInt32` and the
letterbox / decode wraps): int32 activations, int8 weights, no
float dequant. Host mAP stays the §1 float-dequant eval (locked
0.3469). Full Tiny-416 does not fit DCCM; Step 3 gates are per-op
ISS/RTL plus `validate_graph_ops` on the exported integer graph.
Streaming is §4.

The §2 box is **unmasked only** (`vm=1`). Masked via `v0` was
locked as “if GCC asks” and was not built. If autovec or the JIT
emits a masked op, change the C (or the kernel) so every vector
insn is `vm=1`. Do not grow the ISA on day one.

- [x] `ops.yaml` + codegen for every op from §1
- [x] conv2d: im2col + existing GEMM until a conv engine exists
- [x] leaky ReLU, max-pool → RVV
- [x] Remaining YOLO ops (upsample, concat, …) → RVV or scalar
- [x] Tests under `tests/pyvedas/` per new op (ISS + RTL)

---

## 4 — Single-core YOLO (it runs)

One cluster, DCCM, GEMM, RVV. Stream tiles if the layer does not
fit. Same ELF on ISS / RTL / card. This step is **bring-up**, not
the published board score.

From §3 / this bring-up, do not treat as already solved:

- Max-pool RVV is only `pad=0` and `W<=64` (`rowmax[64]`). Tiny 416
  early pools (416 / 208 / 104) take the scalar fallback. Strip-mine
  W if those layers should hit the vector box.
- `pyvedas_gemm_job` packs int32 activations with a narrowing cast
  to int8. Eager `pyvedas.conv2d` is int32 matmul. Per-op tests stay
  in range. End-to-end integer mAP is **§5**, not this step.
- FPGA ICCM is **32 KiB**. Decode-on-core Tiny does not fit. The
  card STREAM ELF is **backbone**; host NMS. Sim ICCM is 1 MiB —
  that is not the card.
- Full Tiny was not ISS / RTL lockstepped. Per-op + mini STREAM
  was (`dram_memcpy`, `conv2d_stream`, `yolo_mini_stream`,
  `requant`).
- Card 46/46 is first-N STREAM EOT (Tiny-208 backbone), not a
  published ms/frame.
- STREAM-stub overlay is **80 MHz**. 100 MHz missed with the URAM
  stub. Do not overwrite the locked 100 MHz / 0.483 zve32x-without-
  stub number. Lock an 80 MHz WNS only from that bit’s routed log.

- [x] JIT compiles Tiny end-to-end (no hand YAML)
- [x] Layer-at-a-time / tile-at-a-time through DCCM
- [x] First-design integer mAP > 0 at 208, then 416

First-design integer mAP is host NMS on the `(1, 7)` requant
graph, same Darknet weights as §1. Logged (`--int32 --limit 16`,
coco128):

- 208: **0.002646**
- 416: **0.002152**

These only mean the graph emits a box. Do not put them in the
abstract. Do not equate them with the float-dequant 0.3469.
Published card mAP and ms/frame wait for §5.

---

## 5 — Score + a full-frame card log → arXiv v0

Two software jobs, then one card log, then post. **No RTL. No new
ISA. No bitstream. No HBM.** The §2 box and the 80 MHz STREAM-stub
overlay stay as they are.

The first-design integer graph scored **0.002** because every
`requant_i32` was `(mul=1, shift=7)` (detect heads `>>6`) and
`quantize_int32` dropped the weight scale. A per-out-channel
scale (`_quantize_per_out`) cannot be inverted by scalar
`requant_i32` (channel `scale_w` spans ~10×). The integer graph
therefore quantizes **per layer** (`_quantize_per_tensor`: one
`scale_w` per conv), not per-channel and not one scale for the
whole net. `(M, S)` and bias follow that same per-layer `scale_w`.

A full-frame card run was a multi-hour first-N replay because
STREAM packed weights **inside** the `ow` loop (`c12`: 1536 packs).
The JIT emits three legal nests for the same MACs. Rank them by
timing the generated C on the host (`gcc -O0`, dummy GEMM), then
run the winner on the card. `cache_col` is the one that is 256
packs **and** 6 `im2col`. Then log numbers. Then post.

### Do not

- Do not bake a YOLO table into `codegen_handlers.py`
- Do not grow the §2 ISA (`vmul`, `vle8`, strided / indexed VLSU)
- Do not emit vector loads to the URAM stub (`dram_addr_hit` is
  scalar-only). That is a bitstream.
- Do not grow FPGA ICCM so decode-on-core fits. Card ELF stays
  **backbone**; host NMS, same as §4
- Do not invent a sibling of 0.3469, or a ms/frame, or an 80 MHz
  WNS. Tick `PAPER.md` from logs only
- Do not overwrite the locked 100 MHz / 0.483 zve32x-without-stub
  number. STREAM card logs name **80 MHz**
- Do not start §6 (HBM / L2)

### Order (do not skip, do not invert)

**A — STREAM conv nest** (JIT / runtime only)

Files: `pyvedas/jit/codegen_handlers.py` (`_emit_conv2d_stream`),
`pyvedas/jit/memory/gemm_tiles.py` (`choose_stream_conv_nest`,
`choose_conv_tiles`), `pyvedas/runtime/c/pyvedas_memcpy.c`.

Three legal nests, same tiles, same MACs. `-O0` `im2col` is the
pole. Count **both** packs and gathers; 256 packs alone is not a
win.

| Nest | `c12` packs | `c12` im2col | Host JIT C | Host `c12` 512×6×6 | Card frame |
|------|-------------|--------------|------------|--------------------|------------|
| `cache_col` | **256** | **6** | **0.0024 s** | **0.0089 s** | **295907.7 ms** |
| spatial-outer | 1536 | 6 | 0.0062 s | 0.0518 s | 315857.6 ms |
| `oc`-outer | 256 | 1536 | 0.0112 s | 0.1228 s | 395472.2 ms |

Host: `gcc -O0` of generated C, dummy GEMM (MACs identical, so
they cancel). JIT analog is `tests.unit.test_stream_nest_host`.
`c12` 512×6×6 is `tests/unit/stream_nest_host.c`. Card: un-chunked
Tiny-208, 80 MHz, 192 boxes. Default is `cache_col` when spatial
tiles `<` OC tiles and the col tiles fit DCCM
(`choose_stream_conv_nest`). Early 208 maps stay spatial-outer,
so the full frame is only ~20 s faster even though `c12` is ~6×
on the host. Do not tick “256 packs” and stop.

- [x] Emit all three nests. Generated `c12`
      (`work/yolo_card_208_cal/generated.c` `conv2d_6`): `oh_t=6`,
      `ow_t=1`, `oc_t=4`, `cache_col` → **256** packs **and** **6**
      `im2col` (`stream_col_cache`, `col_tile=27648`). Same 196 KiB
      tiles. `oc`-outer is 1536 gathers. Spatial-outer is 1536 packs
- [x] `choose_conv_tiles`: when `K` is huge, prefer wider `oc_t`
      on equal-MAC ties
- [x] Keep one weight tile in DCCM across `ow` / `oh`. Do not
      re-fetch the weight blob per strip
- [x] Word (int32) `pyvedas_memcpy` for DRAM↔DCCM slabs. The
      byte `-O0` loop is not the STREAM ABI
- [x] RVV only where §2 already exists (leaky, pool, `vm=1`).
      Do not emit `vmul` / `vle8` / indexed to “win” GEMM
- [x] Lockstep `pyvedas.conv2d_stream`, `pyvedas.yolo_mini_stream`
      (also `pyvedas.max_pool2d`). Wide pool must STREAM through
      DCCM with `W_span<=64` (RVV `vmax`); a DRAM walk of
      `16x208x208` does not EOT

Logged (`chunk --size 208 --work-dir work/yolo_card_208_cal --cal`,
80 MHz, `oc` outer, **before** `cache_col` — do not quote as 5A):

- n=26 `conv2d_6` / `c12`: **250802.1 ms**
- n=46 full backbone: **395480.4 ms**

**A2 — `im2col` from DCCM** (JIT / runtime only)

Files: `pyvedas/jit/codegen_handlers.py` (`_emit_conv2d_stream`),
`pyvedas/jit/memory/gemm_tiles.py` (`STREAM_ACT_CAP`). No ISA, no
bitstream, no HBM. Col tiles overlay act/stage slabs; they are
not live together.

- [x] If the nest is **not** `cache_col` and `n*cin*h*w` fits
      `STREAM_ACT_CAP` (65536 i32, 256 KiB), `memcpy` the map to
      DCCM **once**, then `im2col_tile` from that pointer. `c12`
      is `cache_col`: six col tiles already fill 663552 B, so it
      does **not** also stage the map. `im2col` reads DRAM six
      times into `stream_col_cache`. Do not `vle` the stub
- [x] `cache_col` keeps the six `stream_col` tiles, then packs
      `oc`-outer. Do not invert the nest to buy 256 packs with
      1536 `im2col`. Do not put pack in `ow` to buy 6 `im2col`
      with 1536 packs
- [x] Host ranking of the generated C, then card EOT of the
      winner. Numbers in the **A** table. Same 192 boxes

**B — Modular requant pass** (Python; any conv net, not a YOLO
special case)

Files: `models/yolov3_tiny/int32.py` (graph nodes),
`pyvedas/requant_cal.py` (file ABI + apply),
`python -m models.yolov3_tiny calibrate` (writes the YAML),
`eval --int32 --cal FILE` (applies it). Off by default.

- [x] Weight quant is **per layer**, not global and not
      per-out-channel: `_quantize_per_tensor` (one `scale_w` per
      conv). `_quantize_per_out` stays on the int8 float-dequant
      path only. Scalar `requant_i32` cannot invert a ~10×
      per-channel `scale_w`
- [x] Bias in the accumulator: `round(b / (scale_w * scale_x))`,
      not `round(b)`
- [x] Per-layer `(M, S)` — one pair per conv on the existing
      `requant_i32` nodes, `M / 2^S ≈ scale_x * scale_w / scale_y`.
      Per-channel `M[c]` only if the kernel grows
- [x] Core JIT unchanged without the flag. No YOLO constants in
      codegen

**C — Host integer mAP, from a log**

Rebuild the integer graph. Same Darknet weights as §1. Host NMS.

```
python -m models.yolov3_tiny eval --int32 --cal work/requant_cal.yaml --limit 16 --size 208
python -m models.yolov3_tiny eval --int32 --cal work/requant_cal.yaml --limit 16 --size 416
```

- [x] 208, then **416**, coco128 n=16, mAP@0.5 from that stdout
- [x] Must beat **0.002** by a lot (broken → detector). Do not
      invent a sibling of 0.3469. If it is still ~0.002, the
      pass is wrong — do not post

Logged (`--int32 --cal work/requant_cal.yaml --limit 16`):

- 208: **0.274089**
- 416: **0.332537**

**D — One un-chunked card frame**

Same STREAM ELF path as §4 (backbone, host NMS). 80 MHz stub
bit already on the card. After A+B, rebuild ELF + `dram.hex`.

```
python -m models.yolov3_tiny eval --card --cal work/requant_cal.yaml \
  --limit 16 --size 208 --work-dir work/yolo_card_208_cal --eot-timeout 400
```

- [x] One **full-frame** host-EOT (not first-N 1..N replay).
      Tiny-208 allowed to get a number; **416 is what we report**
      when it fits. 416 STREAM `dram.hex` is **22012520 B**, over
      the 16 MiB AXI stub (`DRAM image … exceeds stub limit
      16777216`). Card number is Tiny-208
- [x] Card mAP@0.5 and ms/frame from that `fpga_runner` /
      `models.yolov3_tiny` host-EOT line. Clock is **80 MHz**.
      Do not write “same clock as Dhrystone” (that number is
      100 MHz)
- [x] Write both numbers into **Done** from the log. No
      invented ms/frame

Logged (`eval --card --cal work/requant_cal.yaml --size 208`,
80 MHz, `work/yolo_card_208_cal`). Same 192 boxes on
`000000000009.jpg`. n=1 mAP is not the n=16 number.

- n=16 mAP@0.5 **0.274089** (spatial-outer ELF, `eval_n16.log`)
- `cache_col` un-chunked: **295907.7 ms** (`eval_n1_cachecol.log`)
- spatial-outer un-chunked: 315857.6 ms (n=16 mean)
- `oc`-outer un-chunked: 395472.2 ms (`eval_n1_packhoist.log`)

**E — Post arXiv**

- [x] Tick this file from the C and D logs
- [ ] **Post arXiv**

### Not this step

Only if D is still a scalar walk of URAM **after** `cache_col`
(each is a bitstream and/or a §2 lock break). Do not open these
to make the first arXiv log:

- Vector port `dram_addr_hit` (`vle32` / `vse32` on the stub)
- SEW=8 `vle8` / `vse8` (breaks §2 SEW=32)
- Strided / indexed VLSU (breaks §2 unit-stride)
- `vmul` in the VALU (not the long pole)
- Board HBM + bigger tiles — that is **§6**

---

## 6 — RTL drop: L2 + HBM

Now the working set is real. v1 L2 is a scratch with **named
slots**, not MESI.

### HBM

- [ ] HBM AXI master (U280 HBM)
- [ ] Address map: weights and activations in HBM
- [ ] Burst DMA HBM ↔ L2
- [ ] FPGA: HBM IP, clocks / resets / init
- [ ] Host: weights (+ command buffers later) into HBM
- [ ] Host: EOT, boxes out
- [ ] ISS HBM; lockstep on a DMA test

### L2

- [ ] Banked, software-managed SRAM
- [ ] Named slots the JIT allocates (base, size, id)
- [ ] Bank arbiter: DMA + cluster 0 (cluster 1 in §7)
- [ ] Slot fence visible to the scalar
- [ ] Counters: occupancy, hits / stalls, HBM bytes
- [ ] ISS L2 + fence; lockstep
- [ ] JIT tiles against L2 budget, not DCCM
- [ ] Single-core YOLO again, now from HBM (log bytes/MAC)

---

## 7 — RTL drop: second core

- [ ] Cluster 1 (scalar + GEMM + RVV; conv if it exists) on the
      same L2 / HBM
- [ ] L2 arbiter: DMA + cluster 0 + cluster 1
- [ ] Per-cluster mailbox / doorbell
- [ ] ISS two-cluster
- [ ] FPGA dual-cluster bring-up
- [ ] `pd-report` of cluster+L2 when we want the receipt

---

## 8 — Job scheduler (this is `place()`)

The JIT assigns tiles to clusters. No per-layer YAML.

- [ ] Descriptor both sides speak:
      `{op, shapes, HBM src/dst, L2 slots, cluster, fence}`
- [ ] Command-buffer walk + doorbell + fence
- [ ] ISS descriptor / doorbell
- [ ] JIT emits two streams (or one ELF, two mailboxes)
- [ ] Cost model: tile bytes, free slots, producer cluster,
      conv vs GEMM cycles, HBM round-trip
- [ ] Hand maps to beat: spatial split, layer-split
- [ ] Second net, same JIT (YOLO11n / attention block / small ViT)

---

## 9 — Test everything (ASPLOS / MLSys table)

Gate: scheduler vs 1-cluster and vs the hand maps (T1), same JIT
on two nets (T3). Beat or match the hand map on ms/frame **or**
on engineer-hours.

- [ ] T1: hand vs JIT × 1- vs 2-cluster (ms/frame, mAP@0.5,
      engineer-hours, HBM bytes/MAC, L2 occupancy)
- [ ] T2: tiling policy × L2 size
- [ ] T3: Tiny + second net
- [ ] Software-baseline appendix
- [ ] Gemmini 8×8 checkbox if cheap
- [ ] `pd-report` Fmax/WNS
- [ ] Native conv engine only if the §1 graph says im2col+GEMM is
      the wrong default (separate RTL drop; not on the critical
      path)

---

## Only if the logs scream

Do not build these **in order** to change venue.

- [ ] Coherent L2 stub (ablation only)
- [ ] Surprising L2 hit / stall vs HBM-only
- [ ] Surprising HBM bytes/MAC
- [ ] 2-cluster speedup vs bank count
- [ ] Power / TOPS/W (T4) — ISCA gate
- [ ] F6 if one of the above is the sentence people quote
- [ ] FCCM / DATE only if the JIT is still 1-cluster when card +
      GDS exist (not the goal)

---

## Rules that still matter

- No invented metrics. Locked numbers are the checked facts under
  **Done**.
- Do not claim world’s first, a Gemmini/Arm/GPU bake-off, Tiny as
  the only 2027 result, or that dual-cluster+L2 is the contribution.
- A human tile map is not a JIT. UART / 100× smoke stay in
  Implementation.
- v1 L2 is named slots. Coherence is an ablation, not the ABI.
- The scheduler must see: cluster id, L2 slot, HBM addr, op, tile
  `(m,n,k)` or conv window.
- Opposite T1 outcomes are publishable (match hand map, zero hours).
  Losing **and** still needing a YAML is not.

---

## Submit checklist

- [ ] arXiv: single-core YOLO on the card **after §5**; integer /
      card mAP from a log, not the 0.002 first-design requant
- [ ] ASPLOS/MLSys: the sentence is **the JIT placed the tiles**
- [ ] T1 would hurt if reversed (JIT worse *and* still needs a YAML)
- [ ] Tiny **and** a second net, same compiler
- [ ] Process footnote on any area/power compare
- [ ] Artifact rebuilds T1–T3 from the repo
- [ ] Title still matches the JIT unless opportunistic data stole it
- [ ] ASPLOS: 11 pages; first two pages stand alone
