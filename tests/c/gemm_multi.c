#include "soc_defines.h"
#include "gemm_csrs.h"

extern void eot_sequence(void);

#define POISON 0x5A5A5A5A

#define A1 0x00101000u
#define B1 0x00101040u
#define C1 0x00101080u

#define A2 0x00101200u
#define B2 0x00101240u
#define C2 0x00101280u

#define A3 0x00101400u
#define B3 0x00101600u
#define C3 0x00101800u

static void hang(void) {
  for (;;)
    ;
}

static void mmio_sw(unsigned addr, unsigned val) {
  *(volatile unsigned *)addr = val;
}

static void start_gemm(unsigned a, unsigned b, unsigned c, unsigned m, unsigned n,
                       unsigned k) {
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_BASE_A, a);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_BASE_B, b);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_BASE_C, c);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_M, m);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_N, n);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_K, k);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_CTRL, GEMM_CTRL_START);
}

static void poison_c(int *c, int nwords) {
  int i;
  for (i = 0; i < nwords; i++)
    c[i] = POISON;
}

int main(void) {
  unsigned char *a1 = (unsigned char *)A1;
  unsigned char *b1 = (unsigned char *)B1;
  int *c1 = (int *)C1;
  unsigned char *a2 = (unsigned char *)A2;
  unsigned char *b2 = (unsigned char *)B2;
  int *c2 = (int *)C2;
  unsigned char *a3 = (unsigned char *)A3;
  unsigned char *b3 = (unsigned char *)B3;
  int *c3 = (int *)C3;
  int i, j, t;

  /* Job 1: 8x8x8. A[i,k]=i+1, B=1 => C[i,j]=8*(i+1).
     Leaves m0/n0 at the end of an 8-wide tile walk. */
  for (i = 0; i < 8; i++) {
    for (t = 0; t < 8; t++) {
      a1[i * 8 + t] = (unsigned char)(i + 1);
      b1[t * 8 + i] = 1;
    }
  }
  poison_c(c1, 64);
  start_gemm(A1, B1, C1, 8, 8, 8);
  for (i = 0; i < 8; i++)
    for (j = 0; j < 8; j++)
      if (c1[i * 8 + j] != 8 * (i + 1))
        hang();

  /* Job 2: 5x3x4 remainder at new addresses. A=2, B=3 => C=24.
     C2 is a full 8x8 poison window. Leftover m_tile/n_tile=8 writes
     past the 5x3 result; leftover m0/n0 skips the tile and leaves poison. */
  for (i = 0; i < 5; i++)
    for (t = 0; t < 4; t++)
      a2[i * 4 + t] = 2;
  for (t = 0; t < 4; t++)
    for (j = 0; j < 3; j++)
      b2[t * 3 + j] = 3;
  poison_c(c2, 64);
  start_gemm(A2, B2, C2, 5, 3, 4);
  for (i = 0; i < 5; i++)
    for (j = 0; j < 3; j++)
      if (c2[i * 3 + j] != 24)
        hang();
  for (i = 15; i < 64; i++)
    if (c2[i] != POISON)
      hang();
  for (i = 0; i < 8; i++)
    for (j = 0; j < 8; j++)
      if (c1[i * 8 + j] != 8 * (i + 1))
        hang();

  /* Job 3: 8x8x40 so K walks two tiles and ping flips.
     A=1, B=1 => C=40. Then job 4 is K=1; leftover k0/k_tile/ping/clear_acc
     would accumulate the previous K panel or read the wrong A/B buffer. */
  for (i = 0; i < 8; i++)
    for (t = 0; t < 40; t++)
      a3[i * 40 + t] = 1;
  for (t = 0; t < 40; t++)
    for (j = 0; j < 8; j++)
      b3[t * 8 + j] = 1;
  poison_c(c3, 64);
  start_gemm(A3, B3, C3, 8, 8, 40);
  for (i = 0; i < 64; i++)
    if (c3[i] != 40)
      hang();

  /* Job 4: reuse job-1 buffers with different A/B. A=1, B[k,j]=j+1
     => C[i,j]=8*(j+1). Stale A/B tiles from job 1 give 8*(i+1) instead. */
  for (i = 0; i < 8; i++) {
    for (t = 0; t < 8; t++) {
      a1[i * 8 + t] = 1;
      b1[t * 8 + i] = (unsigned char)(i + 1);
    }
  }
  poison_c(c1, 64);
  start_gemm(A1, B1, C1, 8, 8, 8);
  for (i = 0; i < 8; i++)
    for (j = 0; j < 8; j++)
      if (c1[i * 8 + j] != 8 * (j + 1))
        hang();
  for (i = 0; i < 64; i++)
    if (c3[i] != 40)
      hang();

  /* Job 5: 8x8x1 on C2. Leftover k_tile=40 / clear_acc=0 keeps the 40. */
  for (i = 0; i < 8; i++)
    a2[i] = 4;
  for (j = 0; j < 8; j++)
    b2[j] = 5;
  poison_c(c2, 64);
  start_gemm(A2, B2, C2, 8, 8, 1);
  for (i = 0; i < 64; i++)
    if (c2[i] != 20)
      hang();

  eot_sequence();
  return 0;
}
