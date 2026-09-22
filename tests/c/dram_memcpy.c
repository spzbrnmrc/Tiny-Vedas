#include "soc_defines.h"
#include <stdint.h>

extern void eot_sequence(void);

#define N 8

static void copy32(int32_t *dst, const int32_t *src, int n) {
    int i;
    for (i = 0; i < n; i++) {
        dst[i] = src[i];
    }
}

int main(void) {
    volatile int32_t *dram = (volatile int32_t *)(uintptr_t)DRAM_BASE;
    int32_t dccm[N];
    int32_t back[N];
    int i;

    for (i = 0; i < N; i++) {
        dram[i] = (int32_t)(100 + i);
    }
    copy32(dccm, (const int32_t *)(uintptr_t)DRAM_BASE, N);
    for (i = 0; i < N; i++) {
        if (dccm[i] != (int32_t)(100 + i)) {
            for (;;) {
            }
        }
        dccm[i] += 1;
    }
    copy32((int32_t *)(uintptr_t)DRAM_BASE, dccm, N);
    copy32(back, (const int32_t *)(uintptr_t)DRAM_BASE, N);
    for (i = 0; i < N; i++) {
        if (back[i] != (int32_t)(101 + i)) {
            for (;;) {
            }
        }
    }
    eot_sequence();
    return 0;
}
