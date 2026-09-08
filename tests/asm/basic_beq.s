    .globl   _start
    .section .text

_start:
    beq      x0, x0, target
    li       x1, 0xdeadbeef   # Should not be executed

target:
    lui      x1, 0x10
    beq      x0, x1, fail
    li       x2, 0x10000
    bne      x1, x2, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
