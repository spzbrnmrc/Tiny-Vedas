#ifndef PYVEDAS_H
#define PYVEDAS_H

#include <stddef.h>
#include <stdint.h>

/* Host and bare-metal callable runtime ("our CUDA").
 *
 * Each function implements one GraphModule op (1:1 with runtime/ops.yaml).
 * Signatures use flat vectors only — there are no tensors at runtime, just
 * (pointer, numel) buffers. Rank is a compile-time concern in generated.c.
 */

void pyvedas_aten_add_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

void pyvedas_aten_mul_Tensor(
    const int32_t *a,
    const int32_t *b,
    int32_t *out,
    size_t n
);

#endif
