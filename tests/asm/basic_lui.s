    .globl   _start
    .section .text

_start:
    lui      x1, 0x10
    li       x2, 0x10000
    bne      x1, x2, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
