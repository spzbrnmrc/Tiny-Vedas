    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    li       x2, 0xfeadbeef
    li       x3, 0x2
    add      x31, x1, x3
    slt      x30, x1, x2
    sltu     x29, x1, x2
    xor      x28, x1, x2
    or       x27, x1, x2
    and      x26, x1, x2
    sll      x25, x1, x3
    srl      x24, x1, x3
    sra      x24, x1, x3
    li       x5, 0xdeadbef1
    bne      x31, x5, fail
    li       x5, 1
    bne      x30, x5, fail
    bne      x29, x5, fail
    li       x5, 0x20000000
    bne      x28, x5, fail
    li       x5, 0xfeadbeef
    bne      x27, x5, fail
    li       x5, 0xdeadbeef
    bne      x26, x5, fail
    li       x5, 0x7ab6fbbc
    bne      x25, x5, fail
    li       x5, 0xf7ab6fbb
    bne      x24, x5, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
