    .globl   _start
    .section .text

    # Heavy DIV/REM/DIVU/REMU regression for Tiny-Vedas divide unit.
    # Covers trivial cases, 4-bit small_div fast path, and non-restoring slow path.
    # Golden values match tools/rv_iss.py (RISC-V M-extension semantics).

_start:
    # --- Divide by zero (signed) ---
    li       x1, 0x12345678
    li       x2, 0
    div      x3, x1, x2          # x3 = 0xFFFFFFFF
    rem      x4, x1, x2          # x4 = 0x12345678

    # --- Divide by one ---
    li       x2, 1
    div      x5, x1, x2          # x5 = 0x12345678
    rem      x6, x1, x2          # x6 = 0x00000000

    # --- Dividend zero ---
    li       x1, 0
    li       x2, 7
    div      x7, x1, x2          # x7 = 0x00000000
    rem      x8, x1, x2          # x8 = 0x00000000

    # --- Signed overflow: INT_MIN / -1 ---
    li       x1, 0x80000000
    li       x2, -1
    div      x9, x1, x2          # x9 = 0x80000000
    rem      x10, x1, x2         # x10 = 0x00000000

    # --- Small fast path (4-bit magnitudes): 13 / 4 ---
    li       x1, 13
    li       x2, 4
    div      x11, x1, x2         # x11 = 0x00000003
    rem      x12, x1, x2         # x12 = 0x00000001

    # --- Small fast path signed: -7 / 3 ---
    li       x1, -7
    li       x2, 3
    div      x13, x1, x2         # x13 = 0xFFFFFFFE
    rem      x14, x1, x2         # x14 = 0xFFFFFFFF

    # --- Slow path signed: 0xDEADBEEF / 2 ---
    li       x1, 0xdeadbeef
    li       x2, 2
    div      x15, x1, x2         # x15 = 0xEF56DF78
    rem      x16, x1, x2         # x16 = 0x00000001

    # --- Slow path signed remainder: 0xDEADBEEF % 7 ---
    li       x2, 7
    rem      x17, x1, x2         # x17 = 0xFFFFFFFB

    # --- Slow path unsigned ---
    li       x1, 0xFEDCBA98
    li       x2, 0x12345
    divu     x18, x1, x2         # x18 = 0x0000E000
    remu     x19, x1, x2         # x19 = 0x00005A98

    # --- Small fast path boundary: 15 / 15 ---
    li       x1, 15
    li       x2, 15
    div      x20, x1, x2         # x20 = 0x00000001
    rem      x21, x1, x2         # x21 = 0x00000000

    # --- Just above small path (bit 4 set): 16 / 4 ---
    li       x1, 16
    li       x2, 4
    div      x22, x1, x2         # x22 = 0x00000004

    # --- Divide by zero (unsigned) ---
    li       x1, 0xABCDEF01
    li       x2, 0
    divu     x23, x1, x2         # x23 = 0xFFFFFFFF
    remu     x24, x1, x2         # x24 = 0xABCDEF01

    # --- Slow path: INT_MIN / 2 ---
    li       x1, 0x80000000
    li       x2, 2
    div      x25, x1, x2         # x25 = 0xC0000000
    rem      x26, x1, x2         # x26 = 0x00000000

    # --- Mixed signs slow path: -100 / 30 ---
    li       x1, -100
    li       x2, 30
    div      x27, x1, x2         # x27 = 0xFFFFFFFD
    rem      x28, x1, x2         # x28 = 0xFFFFFFF6

    # --- Slow path: -2 / -1 ---
    li       x1, -2
    li       x2, -1
    div      x29, x1, x2         # x29 = 0x00000002
    rem      x30, x1, x2         # x30 = 0x00000000

    # --- Unsigned near-max ---
    li       x1, -1                # x1 = 0xFFFFFFFF
    li       x2, -2                # x2 = 0xFFFFFFFE
    divu     x31, x1, x2         # x31 = 0x00000001

    # --- Small signed slow (|rs1| fits in 4 bits but rs2 sign extends): 1 / -7 ---
    li       x1, 1
    li       x2, -7
    div      x3, x1, x2          # x3 = 0x00000000
    rem      x4, x1, x2          # x4 = 0x00000001

    nop
    nop
    nop
    .include "eot_sequence.s"
