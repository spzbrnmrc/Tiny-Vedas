    .globl   _start
    .section .text

_start:
    li       x1, 0xFFFFFFFF
    li       x2, 0xFFFFFFFE
    sub      x3, x1, x2
    li       x4, 1
    bne      x3, x4, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
