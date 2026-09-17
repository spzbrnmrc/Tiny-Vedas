/* FPGA hang canary: UART then two t0 countdowns. */
    .globl   _start
    .section .text
_start:
    .include "soc_defines.inc"
    li       x31, MMIO_UART_ADDR
    li       x30, 'O'
    sw       x30, 0(x31)
    li       t0, 64
1:
    addi     t0, t0, -1
    bnez     t0, 1b
    li       x30, 'K'
    sw       x30, 0(x31)
    li       t0, 64
2:
    addi     t0, t0, -1
    bnez     t0, 2b
    li       x30, 10
    sw       x30, 0(x31)
    .include "eot_sequence.s"
