    .globl   _start
    .section .text

_start:
    lbu      x1, .rodata
    beq      x1, x0, fail
    li       x2, 0xef
    bne      x1, x2, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"

    .section .rodata
    .word    0xDEADBEEF
