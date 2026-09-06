# Alveo U280 FPGA shell (Slice B)

Custom Vivado **2023.2** QDMA + Tiny-Vedas RV32IM.

| Clock | Rate | Domain |
|-------|------|--------|
| QDMA `axi_aclk` | ~250 MHz | AXI-Lite, host mem, CTRL |
| MMCM `core_clk` | **100 MHz** | `core_top`, core mem port |

CDC: SVLib [`cdc_sync`](../../SVLib/src/cdc/cdc_sync.sv). Memories on `core_clk` only (halt-and-load). AXI mem ops while `core_run=1` → SLVERR.

## Build bitstream

```bash
make fpga alveo_u280
# or: make -C fpga/alveo_u280 bitstream
```

Bit: `work/tiny_vedas_u280.bit`. Timing: `work/timing_summary_routed.rpt`.

## Program + driver

```bash
# Vivado on PATH; sudo for PCIe remove/rescan + BAR verify
make -C fpga/alveo_u280 program
# or:
sudo python3 fpga/alveo_u280/scripts/program_fpga.py
sudo python3 fpga/alveo_u280/scripts/program_fpga.py --bit fpga/alveo_u280/work/tiny_vedas_u280.bit
```

What it does: JTAG-program `work/tiny_vedas_u280.bit` → unload `qdma-pf` → PCIe remove/rescan → reload driver → check VERSION.

Manual fallback: Vivado HW Manager, then remove/rescan + `sudo modprobe qdma-pf` (patched 2023.2.1 — see `scripts/patch_qdma_driver.sh`).

Expect **BAR2 = 64 KiB**, VERSION `0x000B0005`.

## Automated smoke (load ICCM + run)

```bash
# root needed to mmap BAR2
sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py           # EOT only
sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py --prog uart
sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py --bin fpga/alveo_u280/sw/prebuilt/eot_smoke.bin
```

What it does: check VERSION / HEARTBEAT / SCRATCH / MMCM locked → halt → load RV32 image into ICCM @ BAR2 `0x4000` → set reset vector `0x00100000` → run → wait EOT → print UART.

Rebuild builtins:

```bash
make -C fpga/alveo_u280/sw
```

## BAR2 map (64 KiB)

| Offset | Role |
|--------|------|
| `0x0000` | CTRL / UART / EOT |
| `0x4000` | ICCM (host only while `core_run=0`) |
| `0x8000` | DCCM (host only while `core_run=0`) |

CTRL: `0x00` VERSION, `0x04` SCRATCH, `0x08` HEARTBEAT, `0x0C` CORE_CTRL `[0]=run [1]=locked`, `0x10` RESET_VECTOR, `0x14` EOT, `0x18` EOT_CLEAR, `0x1C`/`0x20`/`0x24` UART.

## Notes

- Card still on Slice A shows VERSION `0x000A0001` and BAR2 8 KiB — smoke will refuse; program the Slice B bit first.
- ICCM is shared [`rtl/lib/mem_lib.sv`](../../rtl/lib/mem_lib.sv) (aligned word fetch, 1-cycle, BRAM). FPGA halt-and-loads via the write port; sim uses `$readmemh`.
- Slice C: full ELF/`smoke.tlist` runner after the next bit proves UART+bne.
