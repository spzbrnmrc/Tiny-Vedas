    .globl   _start
    .section .text
_start:
    li       x3, 0x00100400
    li       x1, 0x11223344
    sw       x1, 0(x3)
    lw       x2, 0(x3)
    bne      x1, x2, fail
    .include "eot_sequence.s"
fail:
    j        fail
