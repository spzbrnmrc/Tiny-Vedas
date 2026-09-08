    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    li       x2, 0xdeadbeef
    bne      x1, x2, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
