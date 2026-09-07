    .globl   _start
    .section .text
_start:
    li       x1, 0x11223344
    sw       x1, 0(x0)
    nop
    nop
    nop
    nop
    nop
    lw       x2, 0(x0)
    nop
    nop
    nop
    nop
    nop
    bne      x1, x2, fail
    .include "eot_sequence.s"
fail:
    j        fail
