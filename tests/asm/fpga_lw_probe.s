    .globl   _start
    .section .text
_start:
    li       x1, 0x11223344
    sw       x1, 0(x0)
    nop
    nop
    nop
    nop
    lw       x2, 0(x0)
    nop
    nop
    sw       x2, 64(x0)
    .include "eot_sequence.s"
