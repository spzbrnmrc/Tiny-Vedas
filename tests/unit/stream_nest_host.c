#define _POSIX_C_SOURCE 200809L
/*
 * Host -O0 timing of Tiny-208 c12 STREAM nests (im2col + pack only).
 * GEMM is a dummy sink so the ranking matches the FPGA pole, not x86 matmul.
 *
 *   gcc -std=c11 -O0 -I pyvedas/runtime/include \
 *     tests/unit/stream_nest_host.c pyvedas/runtime/c/pyvedas_conv2d.c \
 *     pyvedas/runtime/c/pyvedas_memcpy.c -o work/unit/stream_nest_host
 */
#include "pyvedas.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define N 1
#define CIN 512
#define COUT 1024
#define H 6
#define W 6
#define KH 3
#define KW 3
#define OH 6
#define OW 6
#define OH_T 6
#define OW_T 1
#define OC_T 4
#define KDIM (CIN * KH * KW)
#define M_T (N * OH_T * OW_T)
#define COL_TILE (M_T * KDIM)
#define SPATIAL 6
#define ACT_N (N * CIN * H * W)

static int32_t act[ACT_N];
static int8_t weight[COUT * CIN * KH * KW];
static int32_t stream_act[ACT_N];
static int32_t stream_col[COL_TILE * SPATIAL];
static int32_t stream_wt[KDIM * OC_T];
static volatile int32_t sink;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void dummy_gemm(const int32_t *col, const int32_t *wt) {
    sink ^= col[0] ^ wt[0];
}

static void nest_oc_outer(void) {
    size_t oc0, oh0, ow0;
    pyvedas_memcpy(stream_act, act, ACT_N * sizeof(int32_t));
    for (oc0 = 0; oc0 < COUT; oc0 += OC_T) {
        pyvedas_pack_weight_i8_crs_tile(
            weight, stream_wt, COUT, CIN, KH, KW, oc0, OC_T);
        for (oh0 = 0; oh0 < OH; oh0 += OH_T) {
            for (ow0 = 0; ow0 < OW; ow0 += OW_T) {
                pyvedas_im2col_tile(
                    stream_act, stream_col, N, CIN, H, W, KH, KW, 1, 1,
                    OH, OW, oh0, ow0, OH_T, OW_T);
                dummy_gemm(stream_col, stream_wt);
            }
        }
    }
}

static void nest_spatial_outer(void) {
    size_t oc0, oh0, ow0;
    pyvedas_memcpy(stream_act, act, ACT_N * sizeof(int32_t));
    for (oh0 = 0; oh0 < OH; oh0 += OH_T) {
        for (ow0 = 0; ow0 < OW; ow0 += OW_T) {
            pyvedas_im2col_tile(
                stream_act, stream_col, N, CIN, H, W, KH, KW, 1, 1,
                OH, OW, oh0, ow0, OH_T, OW_T);
            for (oc0 = 0; oc0 < COUT; oc0 += OC_T) {
                pyvedas_pack_weight_i8_crs_tile(
                    weight, stream_wt, COUT, CIN, KH, KW, oc0, OC_T);
                dummy_gemm(stream_col, stream_wt);
            }
        }
    }
}

static void nest_cache_col(void) {
    size_t oc0, oh0, ow0, si;
    pyvedas_memcpy(stream_act, act, ACT_N * sizeof(int32_t));
    si = 0;
    for (oh0 = 0; oh0 < OH; oh0 += OH_T) {
        for (ow0 = 0; ow0 < OW; ow0 += OW_T) {
            pyvedas_im2col_tile(
                stream_act, stream_col + si * COL_TILE, N, CIN, H, W, KH, KW,
                1, 1, OH, OW, oh0, ow0, OH_T, OW_T);
            si++;
        }
    }
    for (oc0 = 0; oc0 < COUT; oc0 += OC_T) {
        pyvedas_pack_weight_i8_crs_tile(
            weight, stream_wt, COUT, CIN, KH, KW, oc0, OC_T);
        si = 0;
        for (oh0 = 0; oh0 < OH; oh0 += OH_T) {
            for (ow0 = 0; ow0 < OW; ow0 += OW_T) {
                dummy_gemm(stream_col + si * COL_TILE, stream_wt);
                si++;
            }
        }
    }
}

static double time_nest(void (*fn)(void), int repeats) {
    int i;
    double t0, t1;
    fn();
    t0 = now_s();
    for (i = 0; i < repeats; i++) {
        fn();
    }
    t1 = now_s();
    return (t1 - t0) / (double)repeats;
}

int main(void) {
    size_t i;
    int repeats = 3;
    for (i = 0; i < ACT_N; i++) {
        act[i] = (int32_t)((i * 17u) & 127u) - 64;
    }
    for (i = 0; i < (size_t)COUT * CIN * KH * KW; i++) {
        weight[i] = (int8_t)((i * 13u) & 15u) - 8;
    }
    printf("c12 host -O0 im2col+pack (dummy GEMM) sink=%d\n", (int)sink);
    printf("oc_outer      %.4fs  packs=256  im2col=1536\n",
           time_nest(nest_oc_outer, repeats));
    printf("spatial_outer %.4fs  packs=1536 im2col=6\n",
           time_nest(nest_spatial_outer, repeats));
    printf("cache_col     %.4fs  packs=256  im2col=6\n",
           time_nest(nest_cache_col, repeats));
    printf("sink=%d\n", (int)sink);
    return 0;
}
