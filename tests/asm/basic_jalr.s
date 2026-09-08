    .globl   _start
    .section .text

_start:
    jal      x3, target
    li       x5, 0x00100000
    bne      x4, x5, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"

target:
    li       x4, 0x00100000
    jalr     x0, x3, 0
