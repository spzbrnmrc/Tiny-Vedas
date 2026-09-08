    .globl   _start
    .section .text

_start:
    li       x1, 0xcafebabe
    bne      x0, x1, target
    li       x1, 0xdeadbeef   # Should not be executed

target:
    li       x2, 0xcafebabe
    bne      x2, x1, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
