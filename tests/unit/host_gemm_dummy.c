/*
 * Host stand-in for pyvedas_gemm_job. GEMM MACs are identical across
 * STREAM nests; a dummy sink ranks pack+im2col the way the FPGA pole does.
 */
#include "pyvedas.h"

static volatile int32_t sink;

void pyvedas_gemm_job(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t m,
    size_t n,
    size_t k,
    size_t m0,
    size_t n0,
    size_t k0,
    size_t m_t,
    size_t n_t,
    size_t k_t,
    uint8_t *scratch
) {
    (void)out;
    (void)m;
    (void)n;
    (void)k;
    (void)m_t;
    (void)n_t;
    (void)k_t;
    (void)scratch;
    sink ^= a[m0] ^ b[n0 + k0];
}
