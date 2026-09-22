# arXiv v0 — what this Portable Document Format (PDF) is

If someone handed you this file, you are the **writer**. Read it
end to end. Then do **Writer**. You are not an implementer.

This file is the prose lock for the preprint. Visible LaTeX is
`content/`. `PAPER.md` is the old two-cluster plan — ignore it for
title, outline, and claims. Do not invent metrics.

**Author:** Marco Spaziani Brunella / Siliscale /
`marco@siliscale.com`. No Italy. No “Siliscale Consulting, LLC”.
Planning notes live in TeX comments, not in the PDF.

---

## The story

This is the first write-up of **Tiny-Vedas**: infrastructure to design
a RISC-V Artificial Intelligence (AI) accelerator System on Chip
(SoC). You Only Look Once version 3 Tiny (YOLOv3-Tiny) is the running
example. It is not the paper.

The paper is a system-design report. It describes:

1. The base machine: a 4-stage 32-bit RISC-V core supporting
   RV32IM and the RISC-V Vector embedded integer profile
   (Zve32x) as built.
2. How a datapath accelerator is stitched onto that core over the
   bus to form the SoC. The example datapath is an 8×8 integer
   General Matrix Multiply (GEMM) behind Memory-Mapped Input/Output
   (MMIO). No custom RISC-V opcodes.
3. How the PyTorch just-in-time compiler (JIT) lowers a quantized
   graph to C for the stock RISC-V GNU Compiler Collection (GCC),
   and how a new datapath shows up in that JIT: an `ops.yaml` row, a
   codegen handler, a C MMIO runtime, and the hardware YAML so tiles
   match the device.
4. YOLOv3-Tiny as the end-to-end example: the compiler tiles the
   backbone against Data Closely Coupled Memory (DCCM), streams the
   rest, and the card matches the host.

**Goal:** name the system and show that stack is real.

**Non-goals:** A speed, area, or process paper. Field-Programmable
Gate Array (FPGA) and Application-Specific Integrated Circuit (ASIC)
numbers belong in the write-up as “this is real.” They do not run
the story. Not a YOLO bake-off. Not custom RISC-V instructions. Do
not invent a plugin framework — the recipe above is the recipe.

**Claim (one sentence):** Tiny-Vedas is a RISC-V SoC plus a PyTorch
JIT for attaching MMIO datapaths without custom instructions; the
base is RV32IM + Zve32x; GEMM is the stitched accelerator; YOLOv3-Tiny
is the example that the same ELF matches host mean Average Precision
(mAP) on the Instruction Set Simulator (ISS), Register-Transfer Level
(RTL), and the Alveo U280 (U280).

**Title:** Tiny-Vedas: RISC-V Infrastructure for AI Accelerator Design

---

## Locked abstract

`content/abstract.tex` is **LOCKED**. Do not rewrite it. Do not
paraphrase it into a denser claim wall. Typo fixes only if the author
asks. Say “supporting RV32IM” — never “integer multiply” for the M
extension (it includes divide). No clock, area, or seconds in the
abstract.

Verbatim story (LaTeX in `abstract.tex`):

- Tiny-Vedas is an open-source toolkit for designing RISC-V AI
  accelerators.
- Center: in-order, single-issue, four-stage 32-bit RISC-V core
  supporting RV32IM and a Zve32x unit.
- Core + vector can take MMIO datapath accelerators → SoC; this paper
  stitches an 8×8 integer GEMM.
- JIT ingests a PyTorch model, extracts the graph, emits C for stock
  RISC-V GCC; extends cleanly to new datapaths and pre/post (tiling).
- Prove with YOLOv3-Tiny.
- Implemented via OpenROAD ASIC flow on ASAP7 PDK; exercised on FPGA
  (Xilinx Alveo U280).

---

## What the reader should see

Open as a systems paper. Name Tiny-Vedas. Say YOLO is the example.

Then the machine: 4-stage RV32IM, Zve32x as built (vector length
(VLEN)=512, standard element width (SEW)=32, unit-stride, unmasked).
Then the stitch: `gemm_top` on the SoC bus, Control and Status
Registers (CSRs) over Advanced eXtensible Interface (AXI) Lite, START
is a store. Then the JIT: `torch.export` → C → stock GCC; a new
accelerator is an `ops.yaml` entry (`pyvedas.gemm_mmio.default`), a
handler in `codegen_handlers.py`, `runtime/c/gemm_mmio.c`, and the
preset in `hw/presets/`. Do not call a human YAML the JIT. Do not
invent a second datapath.

Then the example. YOLOv3-Tiny does not fit in DCCM. The compiler
tiles convolutions, keeps a working set on-chip, and uses a 16
mebibyte (MiB) on-chip AXI stub. The host does Non-Maximum
Suppression (NMS) and card decode because Instruction Closely Coupled
Memory (ICCM) is 32 kibibytes (KiB). Convolution is GEMM MMIO.
Leaky ReLU and max-pool use Zve32x (`vsetvli` e32/m1, `vle32`,
`vse32`, `vmax`/`vmin`) from `pyvedas_leaky_relu.c` and
`aten_max_pool2d.c` in `work/yolo_card_208_cal/test.elf`.

Then the numbers, each with one job.

- **0.274** — host int32 `--cal`, Tiny-208, coco128 n=16. The example
  compiled.
- **0.274** — card, same graph. The SoC did that math.

Put FPGA and ASIC numbers in Implementation / Evaluation so the
reader sees the machine is real: 80 megahertz (MHz) on the U280,
ASAP7 area split, post-route Fmax **540.23 MHz** (3 gigahertz (GHz)
target is open). Minutes-per-frame may live there too. Do not hang
the abstract on clock, area, or seconds. Do not write 3 GHz as
achieved. Do not put the broken **0.002** integer score in the
abstract.

Close on the infrastructure. If a section does not serve “here is the
machine, here is how a datapath is stitched, here is how the JIT sees
it, YOLO is the example,” cut it.

---

## Locked numbers (do not invent siblings)

- Host mean Average Precision at Intersection-over-Union 0.5
  (mAP@0.5) int32 `--cal work/requant_cal.yaml`, Tiny-208, coco128
  n=16: **0.274089**
- Card mAP@0.5 int32 Tiny-208, coco128 n=16: **0.274089**
  (`eval_n16.log`, spatial-outer ELF). Clock was **80 MHz**.
- Fastest card frame: **`cache_col` 295907.7 ms**
  (`eval_n1_cachecol.log`, n=1). Same 192 boxes on
  `000000000009.jpg` as the other nests. Do not glue n=16 mAP and
  n=1 milliseconds per frame (ms/frame) into one run
- Other nests, same image: spatial-outer **315857.6 ms**; output-
  channel-outer (`oc`-outer) **395472.2 ms** (1536 `im2col` — pack
  hoist only is worse)
- ASAP7 `core_gemm_top` (`rv32im_zve32x`, memories as IOs),
  19 September 2026 OpenROAD finish. Plot:
  `pd/work/layout/hier_area.csv`. CORE **3,187 µm²** / 27,000 cells;
  VECTOR **28,466 µm²** / 258,854 cells; GEMM **19,992 µm²** /
  165,998 cells; OTHER **1,874 µm²** / 14,729 cells
- Post-route `report_clock_min_period`: **540.23 MHz**. 3 GHz
  target is open (WNS **−1517.73 ps**, worst path in the vector
  register file). Do not quote `pd/work/timing_summary.txt`
  (18 September, no vector, 1.048 GHz)
- Card YOLO run is **80 MHz** (STREAM stub bit)

---

## In

- Name the system. Core + Zve32x as the base. GEMM as the stitched
  datapath. JIT recipe for a new MMIO accelerator. YOLO as the
  example.
- `torch.export` → C → stock RISC-V GCC (`-march=rv32im_zve32x`,
  no custom opcode), no per-layer YAML sold as the compiler
- GEMM is MMIO (START over the bus), not an instruction
- New datapath in the JIT: `ops.yaml` + codegen handler + C runtime
  + `hw/presets/` YAML. That is the whole plug. Do not invent a
  framework on top.
- STREAM tiles vs DCCM; default nest `cache_col` when it fits
  (256 packs **and** 6 `im2col` on Tiny-208 `c12`)
- Integer graph + command-line interface (CLI) `--cal` requant (off
  by default; no YOLO table in codegen). Per-layer `scale_w`; scalar
  `requant_i32`
- Zve32x as built (VLEN=512, SEW=32, unit-stride, unmasked). The
  YOLO ELF uses it in leaky ReLU and max-pool (`pyvedas_leaky_relu`,
  `pyvedas_aten_max_pool2d`). Convolution is GEMM, not vector.
- Backing store is an on-chip SRAM AXI stub, 16 MiB at
  `0x40000000`
- FPGA ICCM is 32 KiB; example card ELF is the backbone; host NMS
  and host decode
- U280 + ASAP7 numbers in Implementation / Evaluation. The paper
  does not revolve around them.

---

## Out

- FPGA / ASIC as the contribution. Put the locked clock, area, Fmax,
  and frame times in Implementation / Evaluation. Not in the
  abstract. Not a process bake-off.
- Custom RISC-V instructions / new opcodes / coprocessor ISA.
  GEMM is MMIO.
- YOLO as the contribution. It is the running example.
- A plugin/accelerator Software Development Kit (SDK) we did not
  write. The recipe is `ops.yaml` + handler + C + hw YAML.
- World’s first / Gemmini–Arm–Graphics Processing Unit (GPU) bake-off
  / Tiny as the only 2027 result
- 0.3469, 0.332537, input size 416, or 0.002 in the PDF. We did not
  run 416 on the card. Do not write it.
- **295.9 s/frame** in the abstract (Implementation only: the frame
  finished)
- decode-on-core. Extra RVV we did not build (`vle8`, strided,
  `vmul`). The YOLO ELF *does* use `vle32`/`vse32`/`vmax`/`vmin`.
- A human YAML as if it were the JIT
- The 100 MHz overlay, Worst Negative Slack (WNS) 0.483 ns, or
  Dhrystone. That bit has no 16 MiB stub. The YOLO example did not
  run on it.
- Core **3,462 µm²** / GEMM **20,386 µm²**. That GDS has no vector.

The skeleton in `content/` still has leftover dual-cluster /
level-two cache (L2) / second-net sentences. Delete them. Do not
replace them with a roadmap.

---

## Image artifacts

Copy into `paper/figures/`. Add that directory to `TEXINPUTS` (the
Makefile currently only has `content/`). Do not redraw. Do not use
placeholder `\figbox`.

- **Die (use this):**
  `pd/work/layout/annotated_core_gemm_vector.png`
  Gold CORE, pink VECTOR, cyan GEMM. Areas from
  `pd/work/layout/hier_area.csv`. Regenerated with `make pd-annotate`
  after `rtl2gds` on `rv32im_zve32x`. Caption: the SoC (CORE +
  VECTOR + GEMM). Convolution is GEMM; leaky ReLU and max-pool are
  Zve32x. Area numbers from `hier_area.csv`.
- **Die (do not use):**
  `pd/work/layout/annotated_core_gemm.png` and the Sep 17/18
  `final_*.webp` / `annotated_core_gemm_routed.png`. No vector, or
  not this finish.
- **Card detections (use this):**
  `paper/figures/card_000000000009.jpg`
  (copy of `work/yolo_vis_card/card_000000000009.jpg`). Tiny-208,
  STREAM ELF `work/yolo_card_208_cal`, host NMS, **192** boxes,
  **12** drawn (`--max-boxes 12`), EOT **295906.4 ms**. Same image
  as the nest logs. Caption: running example, host NMS on the
  integer heads. Not a detector-paper figure.
- **Detections (do not use):** `work/yolo_vis/` as it sits. Those
  JPEGs are **416** (`int8` / `int32` without `--cal`). `int8` vis
  is the 0.3469 path — do not put it in the PDF. Host int32 Tiny-208
  if needed:

  `python -m models.yolov3_tiny.visualize --backend int32 --size 208 --cal work/requant_cal.yaml --out-dir work/yolo_vis_208`
- **Do not invent** a tiling cartoon, a two-cluster diagram, or a
  UART screenshot.

---

## Writer

You were handed this file. It is the lock. Obey In / Out / locked
numbers. Do not invent metrics.

You write the preprint. You do not change RTL, the JIT, or YOLO
code except to copy figure files.

**Author:** Marco Spaziani Brunella / Siliscale /
`marco@siliscale.com`. No Italy. No “Siliscale Consulting, LLC”.
Planning notes only in TeX comments, not in the PDF.

**Title:** Tiny-Vedas: RISC-V Infrastructure for AI Accelerator Design

**Abstract:** LOCKED (`content/abstract.tex`). Do not rewrite.

This is a system-design preprint (architecture, how a datapath is
stitched, how the JIT sees it, one running example). YOLOv3-Tiny is
the example. It is not the paper. FPGA and ASIC numbers go in
Implementation / Evaluation so the machine looks real. They do not
run the story. Keep clock, area, and seconds **out of the abstract**.

**Rewrite** body sections under `paper/content/` (not the locked
abstract) and `paper/arxiv/main.tex`. Delete
leftover dual-cluster / L2 / HBM / second-net / “tiny GPU” /
`torch.compile` placement sentences. Do not replace them with a
roadmap. First use of every acronym: Expanded (acronym).

Spine the reader must see, in order:

1. Name Tiny-Vedas.
2. Base machine: 4-stage RV32IM + Zve32x as built (VLEN=512,
   SEW=32, unit-stride, unmasked).
3. Stitch: 8×8 int8 GEMM on the SoC bus, AXI-Lite CSRs, START is a
   store. No custom RISC-V opcodes.
4. JIT: `torch.export` → C → stock RISC-V GCC
   (`-march=rv32im_zve32x`). A new datapath is an `ops.yaml` row, a
   codegen handler, a C MMIO runtime, and the hw YAML. That is the
   whole plug. Do not invent an SDK. Do not call a human YAML the
   JIT.
5. Example: integer YOLOv3-Tiny backbone, tiles vs DCCM, 16 MiB
   SRAM AXI stub at `0x40000000`. Host NMS and host decode (FPGA
   ICCM 32 KiB). Convolution is GEMM MMIO. Leaky ReLU and max-pool
   are Zve32x in the same ELF (`vle32`/`vse32`/`vmax`/`vmin`).
6. Proof the example closed: host and card mAP@0.5 **0.274089**
   (Tiny-208, coco128 n=16, `--cal work/requant_cal.yaml`).
7. Receipts (body, not abstract): U280 **80 MHz**; ASAP7
   `core_gemm_top` CORE 3,187 µm² / 27,000 cells, VECTOR 28,466 µm²
   / 258,854 cells, GEMM 19,992 µm² / 165,998 cells, OTHER
   1,874 µm² / 14,729 cells; post-route Fmax **540.23 MHz** (3 GHz
   target open, WNS −1517.73 ps). `cache_col` 295907.7 ms is n=1;
   do not glue it to n=16 mAP. Do not write 3 GHz as achieved.

**Never write in the PDF:** 0.3469, 0.332537, input size 416, 0.002,
world’s first, Gemmini/Arm/GPU bake-off, 100 MHz overlay, WNS 0.483,
Dhrystone, core 3,462 µm² / GEMM 20,386 µm², 295.9 s/frame in the
abstract.

**Figures:** copy `pd/work/layout/annotated_core_gemm_vector.png`
and `work/yolo_vis_card/card_000000000009.jpg` into
`paper/figures/` (the card JPEG may already be there). Add
`$(ROOT)/figures` to `TEXINPUTS` in `paper/Makefile`. Drop
`\figbox`. Do not use `annotated_core_gemm.png` or `work/yolo_vis/`.
Do not invent a tiling cartoon, two-cluster diagram, or UART
screenshot.

**Build:** `cd paper && make arxiv`. PDF is `paper/build/arxiv/main.pdf`.

Do not post to arXiv. Do not commit unless asked. Bring that PDF
back for sign-off against this file.

