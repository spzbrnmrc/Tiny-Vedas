    .globl   _start
    .section .text

# Minimal repro from c.helloworld printf divide loop.
# mulh x15,x14,x15 -> 0x00000028; srai x13,x15,2 -> 0x0000000A

_start:
    li       x14, 100
    li       x15, 0x66666667
    mulh     x15, x14, x15
    srai     x13, x15, 2
    nop
    nop
    nop
    nop
    nop
    .include "eot_sequence.s"
