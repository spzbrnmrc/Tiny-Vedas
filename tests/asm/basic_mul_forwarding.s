    .globl   _start
    .section .text

_start:
    li       x1, 0xdeadbeef
    li       x2, 0xfeadbeef
    li       x3, 0x3
    mul      x4, x1, x2 # EX1 - EX2 - EX3 - WB
    mul      x5, x1, x2 # ID1 - EX1 - EX2 - EX3
    mul      x5, x1, x2 # ID1 - EX1 - EX2 - EX3
    mul      x5, x1, x2 # ID1 - EX1 - EX2 - EX3
    mul      x5, x1, x2 # ID1 - EX1 - EX2 - EX3
    mul      x5, x1, x2 # ID1 - EX1 - EX2 - EX3
    add      x4, x4, x3 # ID0 - ID1 - EX1 - WB
    li       x5, 0xcafebabe
    li       x5, 0xdeadbeef
    li       x5, 0xcafebabe
    li       x5, 0xdeadbeef
    li       x5, 0xcafebabe
    li       x6, 0x016da324
    bne      x4, x6, fail
    li       x6, 0xcafebabe
    bne      x5, x6, fail
    .include "eot_sequence.s"
    .include "fail_hang.s"
