    .globl   _start
    .section .text

_start:
  auipc   gp,0x15
  addi    gp,gp,180 # 115800 <__global_pointer$>
  addi    a0,gp,-1924 # 11507c <Dhrystones_Per_Second>
  auipc   a2,0x17
  addi    a2,a2,388 # 1178dc <__BSS_END__>
  sub     a2,a2,a0
  li      a1,0
  jal     ra,memset
  .include "eot_sequence.s"

memset:
  li      t1,15
  mv      a4,a0
  bgeu    t1,a2,memset+0x44
  andi    a5,a4,15
  bnez    a5,memset+0xb0
  bnez    a1,memset+0x98
  andi    a3,a2,-16
  andi    a2,a2,15
  add     a3,a3,a4
  sw      a1,0(a4)
  sw      a1,4(a4)
  sw      a1,8(a4)
  sw      a1,12(a4)
  addi    a4,a4,16
  bltu    a4,a3,memset+0x24
  bnez    a2,memset+0x44
  ret
  sub     a3,t1,a2
  slli    a3,a3,0x2
  auipc   t0,0x0
  add     a3,a3,t0
  jr      12(a3)
  sb      a1,14(a4)
  sb      a1,13(a4)
  sb      a1,12(a4)
  sb      a1,11(a4)
  sb      a1,10(a4)
  sb      a1,9(a4)
  sb      a1,8(a4)
  sb      a1,7(a4)
  sb      a1,6(a4)
  sb      a1,5(a4)
  sb      a1,4(a4)
  sb      a1,3(a4)
  sb      a1,2(a4)
  sb      a1,1(a4)
  sb      a1,0(a4)
  ret
  zext.b  a1,a1
  slli    a3,a1,0x8
  or      a1,a1,a3
  slli    a3,a1,0x10
  or      a1,a1,a3
  j       memset+0x18
  slli    a3,a5,0x2
  auipc   t0,0x0
  add     a3,a3,t0
  mv      t0,ra
  jalr    -96(a3)
  mv      ra,t0
  addi    a5,a5,-16
  sub     a4,a4,a5
  add     a2,a2,a5
  bgeu    t1,a2,memset+0x44
  j       memset+0x14
