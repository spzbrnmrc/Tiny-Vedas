    .globl   _start
    .section .text

_start:

# Init Memory regions
    sw       x0, 0(x0)
    sw       x0, 4(x0)
    sw       x0, 8(x0)
    sw       x0, 12(x0)
    sw       x0, 16(x0)
    sw       x0, 20(x0)
    sw       x0, 24(x0)

    li       x1, 0xdeadbeef
# Aligned, full-line stores
    sw       x1, 0(x0)
    sw       x1, 4(x0)
    lw       x2, 0(x0)
    lw       x3, 4(x0)
    bne      x2, x1, fail
    bne      x3, x1, fail

# Byte stores
    li       x31, 0xff
    sb       x31, 4(x0)
    lw       x2, 4(x0)
    li       x3, 0xdeadbeff
    bne      x2, x3, fail

# Aligned, Halfword store
    li       x31, 0xdead
    sh       x31, 8(x0)
    lhu      x2, 8(x0)
    li       x3, 0xdead
    bne      x2, x3, fail
    sh       x31, 10(x0)
    lw       x2, 8(x0)
    li       x3, 0xdeaddead
    bne      x2, x3, fail

# Unaligned, Word Store
    li       x31, 0xcafebabe
    sh       x31, 12(x0)
    sw       x31, 14(x0)
    lw       x2, 12(x0)
    li       x3, 0xbabebabe
    bne      x2, x3, fail
    lw       x2, 16(x0)
    li       x3, 0x0000cafe
    bne      x2, x3, fail

    lw       x2, 0(x0)
    li       x3, 0xdeadbeef
    bne      x2, x3, fail

    .include "eot_sequence.s"
    .include "fail_hang.s"
