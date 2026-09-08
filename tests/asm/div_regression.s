    .globl   _start
    .section .text

    # Heavy DIV/REM/DIVU/REMU regression for Tiny-Vedas divide unit.
    # Covers trivial cases, 4-bit small_div fast path, and non-restoring slow path.
    # Golden values match RISC-V M-extension semantics (check before EOT).

_start:
    # --- Divide by zero (signed) ---
    li       x1, 0x12345678
    li       x2, 0
    div      x3, x1, x2          # x3 = 0xFFFFFFFF
    rem      x4, x1, x2          # x4 = 0x12345678
    li       x5, -1
    bne      x3, x5, fail
    li       x5, 0x12345678
    bne      x4, x5, fail

    # --- Divide by one ---
    li       x2, 1
    div      x5, x1, x2          # x5 = 0x12345678
    rem      x6, x1, x2          # x6 = 0x00000000
    li       x7, 0x12345678
    bne      x5, x7, fail
    bne      x6, x0, fail

    # --- Dividend zero ---
    li       x1, 0
    li       x2, 7
    div      x7, x1, x2          # x7 = 0x00000000
    rem      x8, x1, x2          # x8 = 0x00000000
    bne      x7, x0, fail
    bne      x8, x0, fail

    # --- Signed overflow: INT_MIN / -1 ---
    li       x1, 0x80000000
    li       x2, -1
    div      x9, x1, x2          # x9 = 0x80000000
    rem      x10, x1, x2         # x10 = 0x00000000
    li       x11, 0x80000000
    bne      x9, x11, fail
    bne      x10, x0, fail

    # --- Small fast path (4-bit magnitudes): 13 / 4 ---
    li       x1, 13
    li       x2, 4
    div      x11, x1, x2         # x11 = 0x00000003
    rem      x12, x1, x2         # x12 = 0x00000001
    li       x13, 3
    bne      x11, x13, fail
    li       x13, 1
    bne      x12, x13, fail

    # --- Small fast path signed: -7 / 3 ---
    li       x1, -7
    li       x2, 3
    div      x13, x1, x2         # x13 = 0xFFFFFFFE
    rem      x14, x1, x2         # x14 = 0xFFFFFFFF
    li       x15, -2
    bne      x13, x15, fail
    li       x15, -1
    bne      x14, x15, fail

    # --- Slow path signed: 0xDEADBEEF / 2 ---
    li       x1, 0xdeadbeef
    li       x2, 2
    div      x15, x1, x2         # x15 = 0xEF56DF78
    rem      x16, x1, x2         # x16 = 0xFFFFFFFF
    li       x17, 0xef56df78
    bne      x15, x17, fail
    li       x17, -1
    bne      x16, x17, fail

    # --- Slow path signed remainder: 0xDEADBEEF % 7 ---
    li       x2, 7
    rem      x17, x1, x2         # x17 = 0xFFFFFFFB
    li       x18, -5
    bne      x17, x18, fail

    # --- Slow path unsigned ---
    li       x1, 0xFEDCBA98
    li       x2, 0x12345
    divu     x18, x1, x2         # x18 = 0x0000E000
    remu     x19, x1, x2         # x19 = 0x00005A98
    li       x20, 0xe000
    bne      x18, x20, fail
    li       x20, 0x5a98
    bne      x19, x20, fail

    # --- Small fast path boundary: 15 / 15 ---
    li       x1, 15
    li       x2, 15
    div      x20, x1, x2         # x20 = 0x00000001
    rem      x21, x1, x2         # x21 = 0x00000000
    li       x22, 1
    bne      x20, x22, fail
    bne      x21, x0, fail

    # --- Just above small path (bit 4 set): 16 / 4 ---
    li       x1, 16
    li       x2, 4
    div      x22, x1, x2         # x22 = 0x00000004
    li       x23, 4
    bne      x22, x23, fail

    # --- Divide by zero (unsigned) ---
    li       x1, 0xABCDEF01
    li       x2, 0
    divu     x23, x1, x2         # x23 = 0xFFFFFFFF
    remu     x24, x1, x2         # x24 = 0xABCDEF01
    li       x25, -1
    bne      x23, x25, fail
    li       x25, 0xabcdef01
    bne      x24, x25, fail

    # --- Slow path: INT_MIN / 2 ---
    li       x1, 0x80000000
    li       x2, 2
    div      x25, x1, x2         # x25 = 0xC0000000
    rem      x26, x1, x2         # x26 = 0x00000000
    li       x27, 0xc0000000
    bne      x25, x27, fail
    bne      x26, x0, fail

    # --- Mixed signs slow path: -100 / 30 ---
    li       x1, -100
    li       x2, 30
    div      x27, x1, x2         # x27 = 0xFFFFFFFD
    rem      x28, x1, x2         # x28 = 0xFFFFFFF6
    li       x29, -3
    bne      x27, x29, fail
    li       x29, -10
    bne      x28, x29, fail

    # --- Slow path: -2 / -1 ---
    li       x1, -2
    li       x2, -1
    div      x29, x1, x2         # x29 = 0x00000002
    rem      x30, x1, x2         # x30 = 0x00000000
    li       x31, 2
    bne      x29, x31, fail
    bne      x30, x0, fail

    # --- Unsigned near-max ---
    li       x1, -1                # x1 = 0xFFFFFFFF
    li       x2, -2                # x2 = 0xFFFFFFFE
    divu     x31, x1, x2         # x31 = 0x00000001
    li       x3, 1
    bne      x31, x3, fail

    # --- Small signed slow (|rs1| fits in 4 bits but rs2 sign extends): 1 / -7 ---
    li       x1, 1
    li       x2, -7
    div      x3, x1, x2          # x3 = 0x00000000
    rem      x4, x1, x2          # x4 = 0x00000001
    bne      x3, x0, fail
    li       x5, 1
    bne      x4, x5, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
