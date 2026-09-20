    .globl   _start
    .section .text

_start:
    # A: 5, -3, INT_MIN, INT_MAX, -1, 10
    li       x3, 5
    sw       x3, 0(x0)
    li       x3, -3
    sw       x3, 4(x0)
    lui      x3, 0x80000
    sw       x3, 8(x0)
    lui      x3, 0x80000
    addi     x3, x3, -1
    sw       x3, 12(x0)
    li       x3, -1
    sw       x3, 16(x0)
    li       x3, 10
    sw       x3, 20(x0)

    # B: 3, -8, 0, -1, 1, 10
    li       x3, 3
    sw       x3, 64(x0)
    li       x3, -8
    sw       x3, 68(x0)
    sw       x0, 72(x0)
    li       x3, -1
    sw       x3, 76(x0)
    li       x3, 1
    sw       x3, 80(x0)
    li       x3, 10
    sw       x3, 84(x0)

    vsetivli x1, 6, e32, m1, ta, ma
    vle32.v  v1, (x0)
    li       x10, 64
    vle32.v  v2, (x10)

    vmin.vv  v3, v1, v2
    li       x11, 256
    vse32.v  v3, (x11)
    lw       x2, 256(x0)
    li       x5, 3
    bne      x2, x5, fail
    lw       x2, 260(x0)
    li       x5, -8
    bne      x2, x5, fail
    lw       x2, 264(x0)
    lui      x5, 0x80000
    bne      x2, x5, fail
    lw       x2, 268(x0)
    li       x5, -1
    bne      x2, x5, fail

    vmax.vv  v4, v1, v2
    li       x11, 320
    vse32.v  v4, (x11)
    lw       x2, 320(x0)
    li       x5, 5
    bne      x2, x5, fail
    lw       x2, 324(x0)
    li       x5, -3
    bne      x2, x5, fail
    lw       x2, 328(x0)
    bne      x2, x0, fail
    lw       x2, 332(x0)
    lui      x5, 0x80000
    addi     x5, x5, -1
    bne      x2, x5, fail

    vminu.vv v5, v1, v2
    li       x11, 384
    vse32.v  v5, (x11)
    lw       x2, 392(x0)
    bne      x2, x0, fail
    lw       x2, 396(x0)
    lui      x5, 0x80000
    addi     x5, x5, -1
    bne      x2, x5, fail
    lw       x2, 400(x0)
    li       x5, 1
    bne      x2, x5, fail

    vmaxu.vv v6, v1, v2
    li       x11, 448
    vse32.v  v6, (x11)
    lw       x2, 456(x0)
    lui      x5, 0x80000
    bne      x2, x5, fail
    lw       x2, 460(x0)
    li       x5, -1
    bne      x2, x5, fail
    lw       x2, 464(x0)
    bne      x2, x5, fail

    # ReLU-shaped: max(A, 0)
    vmax.vx  v7, v1, x0
    li       x11, 512
    vse32.v  v7, (x11)
    lw       x2, 512(x0)
    li       x5, 5
    bne      x2, x5, fail
    lw       x2, 516(x0)
    bne      x2, x0, fail
    lw       x2, 520(x0)
    bne      x2, x0, fail
    lw       x2, 524(x0)
    lui      x5, 0x80000
    addi     x5, x5, -1
    bne      x2, x5, fail
    lw       x2, 528(x0)
    bne      x2, x0, fail
    lw       x2, 532(x0)
    li       x5, 10
    bne      x2, x5, fail

    li       x12, -1
    vmin.vx  v8, v1, x12
    li       x11, 576
    vse32.v  v8, (x11)
    lw       x2, 576(x0)
    li       x5, -1
    bne      x2, x5, fail
    lw       x2, 580(x0)
    li       x5, -3
    bne      x2, x5, fail
    lw       x2, 584(x0)
    lui      x5, 0x80000
    bne      x2, x5, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
