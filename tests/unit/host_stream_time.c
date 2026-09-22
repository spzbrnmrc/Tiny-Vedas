#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdint.h>
#include <time.h>

uint8_t host_dram[0x01000000];

int generated_main(void);

int host_nolog(const char *fmt, ...) {
    (void)fmt;
    return 0;
}

int main(void) {
    struct timespec t0, t1;
    double s;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    generated_main();
    clock_gettime(CLOCK_MONOTONIC, &t1);
    s = (double)(t1.tv_sec - t0.tv_sec)
        + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    printf("host_s=%.6f\n", s);
    return 0;
}
