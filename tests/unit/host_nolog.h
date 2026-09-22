#ifndef HOST_NOLOG_H
#define HOST_NOLOG_H
#include <stdint.h>
extern uint8_t host_dram[];
int host_nolog(const char *fmt, ...);
#define printf host_nolog
#endif
