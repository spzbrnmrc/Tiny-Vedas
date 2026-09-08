    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    li       x2, 0xfeadbeef
    addi     x31, x1, 0x1
    slti     x30, x1, 0x1
    sltiu    x29, x1, 0x1
    xori     x28, x1, 0x0ff
    ori      x27, x1, 0x0ff
    andi     x26, x1, 0x00f
    slli     x25, x1, 0x4
    srli     x24, x1, 0x4
    srai     x24, x1, 0x4
    # Check before eot_sequence clobbers x30/x31
    li       x5, 0xdeadbef0
    bne      x31, x5, fail
    li       x5, 1
    bne      x30, x5, fail
    bne      x29, x0, fail
    li       x5, 0xdeadbe10
    bne      x28, x5, fail
    li       x5, 0xdeadbeff
    bne      x27, x5, fail
    li       x5, 0xf
    bne      x26, x5, fail
    li       x5, 0xeadbeef0
    bne      x25, x5, fail
    li       x5, 0xfdeadbee
    bne      x24, x5, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
