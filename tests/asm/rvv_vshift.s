    .globl   _start
    .section .text

_start:
    # A: 8, -8, INT_MIN, 15
    li       x3, 8
    sw       x3, 0(x0)
    li       x3, -8
    sw       x3, 4(x0)
    lui      x3, 0x80000
    sw       x3, 8(x0)
    li       x3, 15
    sw       x3, 12(x0)

    # B: 1, 2, 3, 4
    li       x3, 1
    sw       x3, 64(x0)
    li       x3, 2
    sw       x3, 68(x0)
    li       x3, 3
    sw       x3, 72(x0)
    li       x3, 4
    sw       x3, 76(x0)

    vsetivli x1, 4, e32, m1, ta, ma
    vle32.v  v1, (x0)
    li       x10, 64
    vle32.v  v2, (x10)

    vsll.vv  v3, v1, v2
    li       x11, 256
    vse32.v  v3, (x11)
    lw       x2, 256(x0)
    li       x5, 16
    bne      x2, x5, fail
    lw       x2, 260(x0)
    li       x5, -32
    bne      x2, x5, fail
    lw       x2, 264(x0)
    bne      x2, x0, fail
    lw       x2, 268(x0)
    li       x5, 240
    bne      x2, x5, fail

    li       x12, 1
    vsrl.vx  v4, v1, x12
    li       x11, 320
    vse32.v  v4, (x11)
    lw       x2, 320(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 324(x0)
    lui      x5, 0x80000
    addi     x5, x5, -4
    bne      x2, x5, fail
    lw       x2, 328(x0)
    lui      x5, 0x40000
    bne      x2, x5, fail
    lw       x2, 332(x0)
    li       x5, 7
    bne      x2, x5, fail

    vsra.vi  v5, v1, 1
    li       x11, 384
    vse32.v  v5, (x11)
    lw       x2, 384(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 388(x0)
    li       x5, -4
    bne      x2, x5, fail
    lw       x2, 392(x0)
    lui      x5, 0xc0000
    bne      x2, x5, fail
    lw       x2, 396(x0)
    li       x5, 7
    bne      x2, x5, fail

    vsll.vi  v6, v1, 2
    li       x11, 448
    vse32.v  v6, (x11)
    lw       x2, 448(x0)
    li       x5, 32
    bne      x2, x5, fail
    lw       x2, 452(x0)
    li       x5, -32
    bne      x2, x5, fail
    lw       x2, 456(x0)
    bne      x2, x0, fail
    lw       x2, 460(x0)
    li       x5, 60
    bne      x2, x5, fail

    vsra.vv  v7, v1, v2
    li       x11, 512
    vse32.v  v7, (x11)
    lw       x2, 512(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 516(x0)
    li       x5, -2
    bne      x2, x5, fail
    lw       x2, 520(x0)
    lui      x5, 0xf0000
    bne      x2, x5, fail
    lw       x2, 524(x0)
    bne      x2, x0, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
