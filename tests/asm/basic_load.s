    .globl   _start
    .section .text

_start:
    # Self-init (FPGA has no .mem preload)
    li       x5, 0xdeadbeef
    sw       x5, 0(x0)

    lw       x1, 0(x0)
    lw       x2, 1(x0)
    lw       x3, 2(x0)
    lw       x4, 3(x0)
    lb       x1, 0(x0)
    lb       x2, 1(x0)
    lb       x3, 2(x0)
    lb       x4, 3(x0)
    lh       x1, 0(x0)
    lh       x2, 1(x0)
    lh       x3, 2(x0)
    lh       x4, 3(x0)
    # Final lh results (sign-extended)
    li       x5, 0xffffbeef
    bne      x1, x5, fail
    li       x5, 0xffffadbe
    bne      x2, x5, fail
    li       x5, 0xffffdead
    bne      x3, x5, fail
    li       x5, 0xde
    bne      x4, x5, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
