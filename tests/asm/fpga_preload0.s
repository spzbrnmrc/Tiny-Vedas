    .globl   _start
    .section .text
_start:
    lw       x2, 0(x0)
    li       x1, 0x11223344
    bne      x1, x2, fail
    .include "eot_sequence.s"
fail:
    j        fail
