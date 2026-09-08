# Tight countdown loop — ISS/xsim pass; FPGA used to hang on banked ICCM.
    .globl   _start
    .section .text

_start:
    li       t0, 8
1:
    addi     t0, t0, -1
    bnez     t0, 1b
    .include "eot_sequence.s"
