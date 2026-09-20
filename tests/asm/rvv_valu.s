    .globl   _start
    .section .text

_start:
    # A[i] = i*4 at 0; B[i] = i+1 at 64
    li       x4, 0
    li       x5, 64
fill_a:
    sw       x4, 0(x4)
    addi     x4, x4, 4
    bne      x4, x5, fill_a

    li       x4, 0
fill_b:
    addi     x6, x4, 1
    slli     x7, x4, 2
    add      x7, x7, x5
    sw       x6, 0(x7)
    addi     x4, x4, 1
    li       x6, 16
    bne      x4, x6, fill_b

    vsetvli  x1, x0, e32, m1, ta, ma
    vle32.v  v1, (x0)
    li       x10, 64
    vle32.v  v2, (x10)

    # v3[i] = 4*i + (i+1) = 5*i + 1
    vadd.vv  v3, v1, v2
    li       x11, 256
    vse32.v  v3, (x11)
    lw       x2, 256(x0)
    li       x5, 1
    bne      x2, x5, fail
    lw       x2, 260(x0)
    li       x5, 6
    bne      x2, x5, fail
    lw       x2, 316(x0)
    li       x5, 76
    bne      x2, x5, fail

    li       x12, 3
    vadd.vx  v4, v1, x12
    li       x11, 320
    vse32.v  v4, (x11)
    lw       x2, 320(x0)
    li       x5, 3
    bne      x2, x5, fail
    lw       x2, 324(x0)
    li       x5, 7
    bne      x2, x5, fail
    lw       x2, 380(x0)
    li       x5, 63
    bne      x2, x5, fail

    vadd.vi  v5, v1, 5
    li       x11, 384
    vse32.v  v5, (x11)
    lw       x2, 384(x0)
    li       x5, 5
    bne      x2, x5, fail
    lw       x2, 388(x0)
    li       x5, 9
    bne      x2, x5, fail
    lw       x2, 444(x0)
    li       x5, 65
    bne      x2, x5, fail

    li       x13, 0xA5A5A5A5
    vmv.v.x  v6, x13
    li       x11, 448
    vse32.v  v6, (x11)
    lw       x2, 448(x0)
    bne      x2, x13, fail
    lw       x2, 508(x0)
    bne      x2, x13, fail

    vmv.v.i  v7, -1
    li       x11, 512
    vse32.v  v7, (x11)
    lw       x2, 512(x0)
    li       x5, -1
    bne      x2, x5, fail

    vmv.v.v  v8, v1
    li       x11, 576
    vse32.v  v8, (x11)
    lw       x2, 576(x0)
    bne      x2, x0, fail
    lw       x2, 580(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 636(x0)
    li       x5, 60
    bne      x2, x5, fail

    # vl=4 body + tail ones, then store at vl=16
    vsetivli x1, 4, e32, m1, ta, ma
    vadd.vv  v9, v1, v2
    vsetvli  x1, x0, e32, m1, ta, ma
    li       x11, 640
    vse32.v  v9, (x11)
    lw       x2, 640(x0)
    li       x5, 1
    bne      x2, x5, fail
    lw       x2, 652(x0)
    li       x5, 16
    bne      x2, x5, fail
    lw       x2, 656(x0)
    li       x5, -1
    bne      x2, x5, fail
    lw       x2, 700(x0)
    bne      x2, x5, fail

    # vill: vadd is a nop (v3 stays 5*i+1)
    vsetvli  x1, x0, e16, m1, ta, ma
    vadd.vv  v3, v2, v2
    vsetvli  x1, x0, e32, m1, ta, ma
    li       x11, 256
    vse32.v  v3, (x11)
    lw       x2, 256(x0)
    li       x5, 1
    bne      x2, x5, fail
    lw       x2, 316(x0)
    li       x5, 76
    bne      x2, x5, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
