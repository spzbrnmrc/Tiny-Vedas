#include "soc_defines.h"
#include <stdint.h>

extern void eot_sequence(void);

int main(void) {
    volatile int32_t *dram = (volatile int32_t *)(uintptr_t)DRAM_BASE;
    dram[0] = (int32_t)0x11223344;
    eot_sequence();
    return 0;
}
