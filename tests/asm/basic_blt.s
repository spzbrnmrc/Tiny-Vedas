    .globl   _start
    .section .text

_start:
    li       x1, 0xFFFFFFFF
    blt      x1, x0, target
    li       x1, 0xdeadbeef   # Should not be executed

target:
    li       x2, 0xFFFFFFFE
    blt      x1, x2, fail
    li       x3, -1
    bne      x1, x3, fail
    li       x3, -2
    bne      x2, x3, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
