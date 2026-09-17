#include "soc_defines.h"
#include "gemm_csrs.h"

extern void eot_sequence(void);

#define A_ADDR 0x00101000u
#define B_ADDR 0x00101100u
#define C_ADDR 0x00101200u

static void mmio_sw(unsigned addr, unsigned val) {
  *(volatile unsigned *)addr = val;
}

static unsigned mmio_lw(unsigned addr) {
  return *(volatile unsigned *)addr;
}

int main(void) {
  unsigned char *a = (unsigned char *)A_ADDR;
  unsigned char *b = (unsigned char *)B_ADDR;
  int *c = (int *)C_ADDR;
  int i, k, j;

  for (i = 0; i < 8; i++) {
    for (k = 0; k < 8; k++) {
      a[i * 8 + k] = (unsigned char)(i + 1);
      b[k * 8 + i] = 1;
    }
  }
  for (j = 0; j < 64; j++)
    c[j] = 0;

  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_BASE_A, A_ADDR);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_BASE_B, B_ADDR);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_BASE_C, C_ADDR);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_M, 8);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_N, 8);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_K, 8);
  mmio_sw(MMIO_GEMM_ADDR + GEMM_OFF_CTRL, GEMM_CTRL_START);

  if (c[0] != 8)
    for (;;)
      ;
  if (c[7] != 8)
    for (;;)
      ;
  if (c[56] != 64)
    for (;;)
      ;

  (void)mmio_lw(MMIO_GEMM_ADDR + GEMM_OFF_STATUS);
  eot_sequence();
  return 0;
}
