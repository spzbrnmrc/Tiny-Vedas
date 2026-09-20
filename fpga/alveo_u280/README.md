# Alveo U280 — Tiny-Vedas Slice B/C (zve32x overlay)

## Program + driver reload

```bash
sudo python3 fpga/alveo_u280/scripts/program_fpga.py
```

What it does: JTAG-program `work/tiny_vedas_u280.bit` → unload `qdma-pf` → PCIe remove/rescan → reload driver → check VERSION.

Expect **BAR2 = 2 MiB**, VERSION `0x000B0014` (vector overlay, `rv32im_zve32x`).

## Smoke / runner

```bash
# Slice C — same tests as sim; pass = EOT (+ UART golden when defined)
make fpga_smoke alveo_u280

# Single test / Slice B builtins (manual)
sudo env PATH="/tools/riscv/bin:$$PATH" ./venv/bin/python \
  fpga/alveo_u280/scripts/fpga_runner.py -n c.helloworld
sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py
sudo python3 fpga/alveo_u280/scripts/fpga_smoke.py --prog uart
```

What it does: check VERSION / HEARTBEAT / SCRATCH / MMCM locked → halt → load RV32 image into ICCM @ BAR2 `0x1000` → set reset vector `0x00100000` → run → wait EOT → optional UART golden compare.

Rebuild builtins:

```bash
make -C fpga/alveo_u280/sw
```

## BAR2 map (2 MiB)

| Offset | Role |
|--------|------|
| `0x0000` | CTRL / UART / EOT |
| `0x1000` | ICCM 32 KiB (host only while `core_run=0`) |
| `0x9000` | DCCM 1 MiB (host only while `core_run=0`) |

CTRL: `0x00` VERSION, `0x04` SCRATCH, `0x08` HEARTBEAT, `0x0C` CORE_CTRL `[0]=run [1]=locked`, `0x10` RESET_VECTOR, `0x14` EOT, `0x18` EOT_CLEAR, `0x1C`/`0x20`/`0x24` UART.

## Notes

- Card still on Slice A shows VERSION `0x000A0001` and BAR2 8 KiB — smoke will refuse; program the Slice B bit first.
- ICCM/DCCM are shared [`rtl/lib/mem_lib.sv`](../../rtl/lib/mem_lib.sv) (`ram_style=block`).
- No retire TRACE on FPGA (sim keeps ISS compare). FPGA pass = EOT; prefer self-checking tests that only EOT on success.
- Slice C: `fpga_runner.py` loads ELF `.text`→ICCM / data→DCCM (32 KiB / 1 MiB windows). GEMM CSRs are at SoC `0x00300000` (not a BAR2 window).
