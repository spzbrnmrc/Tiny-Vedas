    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    addi     x1, x0, 0x2
    nop
    addi     x2, x1, 0x1
    li       x3, 2
    bne      x1, x3, fail
    li       x3, 3
    bne      x2, x3, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
