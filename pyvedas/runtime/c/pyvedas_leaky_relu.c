/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Unmasked RVV vmin/vmax plus scalar truncating /10. Scalar fallback for host.
 */

#include "pyvedas.h"

#if defined(__riscv_vector)
#include <riscv_vector.h>
#endif

void pyvedas_leaky_relu(const int32_t *x, int32_t *out, size_t n) {
#if defined(__riscv_vector)
    size_t i = 0;
    while (i < n) {
        size_t vl = __riscv_vsetvl_e32m1(n - i);
        vint32m1_t vx = __riscv_vle32_v_i32m1(x + i, vl);
        vint32m1_t vzero = __riscv_vmv_v_x_i32m1(0, vl);
        vint32m1_t vpos = __riscv_vmax_vv_i32m1(vx, vzero, vl);
        vint32m1_t vneg = __riscv_vmin_vv_i32m1(vx, vzero, vl);
        int32_t tmp[16];
        size_t k;
        __riscv_vse32_v_i32m1(out + i, vpos, vl);
        __riscv_vse32_v_i32m1(tmp, vneg, vl);
        for (k = 0; k < vl; k++) {
            out[i + k] += tmp[k] / 10;
        }
        i += vl;
    }
#else
    size_t i;
    for (i = 0; i < n; i++) {
        int32_t v = x[i];
        out[i] = (v >= 0) ? v : (v / 10);
    }
#endif
}
