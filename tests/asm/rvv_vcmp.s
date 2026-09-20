    .globl   _start
    .section .text

_start:
    # A: 5, -3, 0, 10
    li       x3, 5
    sw       x3, 0(x0)
    li       x3, -3
    sw       x3, 4(x0)
    sw       x0, 8(x0)
    li       x3, 10
    sw       x3, 12(x0)

    # B: 5, 0, -1, 10
    li       x3, 5
    sw       x3, 64(x0)
    sw       x0, 68(x0)
    li       x3, -1
    sw       x3, 72(x0)
    li       x3, 10
    sw       x3, 76(x0)

    vsetivli x1, 4, e32, m1, ta, ma
    vle32.v  v1, (x0)
    li       x10, 64
    vle32.v  v2, (x10)

    # mask[3:0]=1001, tail 1s → 0xFFFFFFF9; dest[1:]=ones
    vmseq.vv v3, v1, v2
    li       x11, 256
    vse32.v  v3, (x11)
    lw       x2, 256(x0)
    li       x5, -7
    bne      x2, x5, fail
    lw       x2, 260(x0)
    li       x5, -1
    bne      x2, x5, fail

    vmsne.vx v4, v1, x0
    li       x11, 320
    vse32.v  v4, (x11)
    lw       x2, 320(x0)
    li       x5, -5
    bne      x2, x5, fail

    vmslt.vv v5, v1, v2
    li       x11, 384
    vse32.v  v5, (x11)
    lw       x2, 384(x0)
    li       x5, -14
    bne      x2, x5, fail

    vmsgt.vi v6, v1, 0
    li       x11, 448
    vse32.v  v6, (x11)
    lw       x2, 448(x0)
    li       x5, -7
    bne      x2, x5, fail

    li       x12, 5
    vmsltu.vx v7, v1, x12
    li       x11, 512
    vse32.v  v7, (x11)
    lw       x2, 512(x0)
    li       x5, -12
    bne      x2, x5, fail

    vmseq.vi v8, v1, 5
    li       x11, 576
    vse32.v  v8, (x11)
    lw       x2, 576(x0)
    li       x5, -15
    bne      x2, x5, fail

    vmsle.vv v9, v1, v2
    li       x11, 640
    vse32.v  v9, (x11)
    lw       x2, 640(x0)
    li       x5, -5
    bne      x2, x5, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
