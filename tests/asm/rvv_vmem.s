    .globl   _start
    .section .text

_start:
    # mem[i*4] = i*4 for i in 0..15
    li       x4, 0
    li       x5, 64
fill:
    sw       x4, 0(x4)
    addi     x4, x4, 4
    bne      x4, x5, fill

    vsetvli  x1, x0, e32, m1, ta, ma
    vle32.v  v1, (x0)

    li       x11, 128
    vse32.v  v1, (x11)

    lw       x2, 128(x0)
    bne      x2, x0, fail
    lw       x2, 132(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 188(x0)
    li       x5, 60
    bne      x2, x5, fail

    # one DLEN beat, dest cleared first
    sw       x0, 256(x0)
    sw       x0, 260(x0)
    sw       x0, 264(x0)
    sw       x0, 268(x0)
    sw       x0, 272(x0)
    vsetivli x1, 4, e32, m1, ta, ma
    vle32.v  v2, (x0)
    li       x11, 256
    vse32.v  v2, (x11)
    lw       x2, 256(x0)
    bne      x2, x0, fail
    lw       x2, 260(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 268(x0)
    li       x5, 12
    bne      x2, x5, fail
    lw       x2, 272(x0)
    bne      x2, x0, fail

    # EEW-aligned but not 16-byte: base+4, vl=3
    sw       x0, 320(x0)
    sw       x0, 324(x0)
    sw       x0, 328(x0)
    sw       x0, 332(x0)
    vsetivli x1, 3, e32, m1, ta, ma
    li       x10, 4
    vle32.v  v3, (x10)
    li       x11, 320
    vse32.v  v3, (x11)
    lw       x2, 320(x0)
    li       x5, 4
    bne      x2, x5, fail
    lw       x2, 324(x0)
    li       x5, 8
    bne      x2, x5, fail
    lw       x2, 328(x0)
    li       x5, 12
    bne      x2, x5, fail
    lw       x2, 332(x0)
    bne      x2, x0, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
