    .globl   _start
    .section .text

_start:
    jal      x2, target

target:
    lui      x1, 0x10
    li       x3, 0x10000
    bne      x1, x3, fail
    li       x3, 0x00100004
    bne      x2, x3, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
