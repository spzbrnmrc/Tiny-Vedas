/* Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * GEMM CSR offsets relative to MMIO_GEMM_ADDR (see soc_defines.h).
 */
#ifndef GEMM_CSRS_H
#define GEMM_CSRS_H

#define GEMM_OFF_BASE_A  0x00
#define GEMM_OFF_BASE_B  0x04
#define GEMM_OFF_BASE_C  0x08
#define GEMM_OFF_M       0x0C
#define GEMM_OFF_N       0x10
#define GEMM_OFF_K       0x14
#define GEMM_OFF_CTRL    0x18
#define GEMM_OFF_STATUS  0x1C

#define GEMM_CTRL_START  (1u << 0)
#define GEMM_CTRL_RESET  (1u << 1)
#define GEMM_STATUS_BUSY (1u << 0)
#define GEMM_STATUS_DONE (1u << 1)

#define GEMM_PE_DIM  8
#define GEMM_K_TILE  32

#endif
