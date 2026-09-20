    .globl   _start
    .section .text

_start:
    li       x2, 16
    vsetvli  x1, x2, e32, m1, ta, ma

    csrr     x3, vl
    bne      x3, x1, fail

    csrr     x4, vtype
    li       x5, 0xD0
    bne      x4, x5, fail

    csrr     x6, vlenb
    li       x5, 64
    bne      x6, x5, fail

    # illegal vtype → vill=1, vl=0
    vsetvli  x1, x2, e8, m1, ta, ma
    bne      x1, x0, fail
    csrr     x3, vl
    bne      x3, x0, fail
    csrr     x4, vtype
    li       x5, 0x80000000
    bne      x4, x5, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
