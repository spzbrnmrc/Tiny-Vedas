    .include "soc_defines.inc"
    .globl   _start
    .section .text

_start:
    /* A @ 0x00101000, B @ 0x00101100, C @ 0x00101200 */
    li   t0, 0x00101000
    li   t1, 0x00101100
    li   t2, 0x00101200

    /* A[i,k] = i+1, B[k,j] = 1  =>  C[i,j] = 8*(i+1) */
    li   t3, 0
.fill_i:
    li   t4, 0
.fill_k:
    slli a0, t3, 3
    add  a0, a0, t4
    add  a1, a0, t0
    addi t5, t3, 1
    sb   t5, 0(a1)
    add  a1, a0, t1
    li   t5, 1
    sb   t5, 0(a1)
    addi t4, t4, 1
    li   t5, 8
    blt  t4, t5, .fill_k
    addi t3, t3, 1
    li   t5, 8
    blt  t3, t5, .fill_i

    li   a0, MMIO_GEMM_ADDR
    sw   t0, 0(a0)
    sw   t1, 4(a0)
    sw   t2, 8(a0)
    li   t3, 8
    sw   t3, 12(a0)
    sw   t3, 16(a0)
    sw   t3, 20(a0)
    li   t3, 1
    sw   t3, 24(a0)

    lw   t3, 0(t2)
    li   t4, 8
    bne  t3, t4, .fail
    lw   t3, 28(t2)
    bne  t3, t4, .fail
    lw   t3, 224(t2)
    li   t4, 64
    bne  t3, t4, .fail

    .include "eot_sequence.s"

.fail:
    j    .fail
