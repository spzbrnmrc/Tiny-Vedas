    .globl   _start
    .section .text

_start:
    # AVL=16 → vl=16 (VLMAX at SEW=32, LMUL=1, VLEN=512)
    li       x2, 16
    vsetvli  x1, x2, e32, m1, ta, ma
    li       x5, 16
    bne      x1, x5, fail

    # AVL=15 → vl=15
    li       x2, 15
    vsetvli  x1, x2, e32, m1, ta, ma
    li       x5, 15
    bne      x1, x5, fail

    # AVL=255 → vl=VLMAX
    li       x2, 255
    vsetvli  x1, x2, e32, m1, ta, ma
    li       x5, 16
    bne      x1, x5, fail

    # rd!=x0, rs1=x0 → VLMAX
    vsetvli  x1, x0, e32, m1, ta, ma
    li       x5, 16
    bne      x1, x5, fail

    # vsetivli uimm=8
    vsetivli x1, 8, e32, m1, ta, ma
    li       x5, 8
    bne      x1, x5, fail

    # vsetvl with vtype in x3
    li       x3, 0xD0
    li       x2, 10
    vsetvl   x1, x2, x3
    li       x5, 10
    bne      x1, x5, fail

    # illegal vtype (e16) → vill, vl=0 written to rd
    li       x2, 16
    vsetvli  x1, x2, e16, m1, ta, ma
    bne      x1, x0, fail

    # rd=x0, rs1=x0 keeps vl after a legal set
    li       x2, 7
    vsetvli  x1, x2, e32, m1, ta, ma
    vsetvli  x0, x0, e32, m1, ta, ma
    # x1 still 7; next csrr in rvv_csrr.s covers CSR keep

    .include "eot_sequence.s"
    .include "fail_hang.s"
