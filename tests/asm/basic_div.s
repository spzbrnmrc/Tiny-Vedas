    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    li       x2, 0x2
    div      x3, x1, x2
    mv       x4, x3
    li       x5, 0xef56df78
    bne      x3, x5, fail
    bne      x4, x5, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
