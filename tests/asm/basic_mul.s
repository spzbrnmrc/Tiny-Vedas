    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    li       x2, 0xfeadbeef
    mul      x3, x1, x2
    mulh     x4, x1, x2
    mulhsu   x5, x1, x2
    mulhu    x6, x1, x2
    li       x7, 0x016da321
    bne      x3, x7, fail
    li       x7, 0x002c0712
    bne      x4, x7, fail
    li       x7, 0xded9c601
    bne      x5, x7, fail
    li       x7, 0xdd8784f0
    bne      x6, x7, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
