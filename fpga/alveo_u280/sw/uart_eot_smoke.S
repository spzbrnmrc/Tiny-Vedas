  .section .text
  .globl _start
_start:
  /* UART + taken-bne canary — reuses t0 across delays (flush hazard stress). */
  li   x31, 0x00200000
  li   x30, 'O'
  sw   x30, 0(x31)
  li   t0, 64
1:
  addi t0, t0, -1
  bnez t0, 1b
  li   x30, 'K'
  sw   x30, 0(x31)
  li   t0, 64
2:
  addi t0, t0, -1
  bnez t0, 2b
  li   x30, '\n'
  sw   x30, 0(x31)
  li   t0, 64
3:
  addi t0, t0, -1
  bnez t0, 3b
  li   x31, 0x10000000
  li   x30, 0xdeadbeef
  sw   x30, 0(x31)
4: j 4b
