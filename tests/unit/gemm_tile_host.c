/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Host dump of pyvedas_gemm_plan for lockstep tests vs the Python planner.
 * Usage: gemm_tile_host M N K SCRATCH_BYTES
 */

#include "gemm_tile.h"

#include <stdio.h>
#include <stdlib.h>

#define JOBS_CAP 8192

int main(int argc, char **argv) {
    size_t m, n, k, budget, mt, nt, kt, nj, i;
    pyvedas_gemm_job_t jobs[JOBS_CAP];

    if (argc != 5) {
        fprintf(stderr, "usage: %s M N K SCRATCH_BYTES\n", argv[0]);
        return 2;
    }
    m = (size_t)strtoull(argv[1], NULL, 10);
    n = (size_t)strtoull(argv[2], NULL, 10);
    k = (size_t)strtoull(argv[3], NULL, 10);
    budget = (size_t)strtoull(argv[4], NULL, 10);

    if (!pyvedas_gemm_choose_tile(m, n, k, budget, &mt, &nt, &kt)) {
        printf("none\n");
        return 0;
    }
    printf("tile %zu %zu %zu\n", mt, nt, kt);
    nj = pyvedas_gemm_plan(m, n, k, budget, jobs, JOBS_CAP);
    printf("njobs %zu\n", nj);
    if (nj > JOBS_CAP) {
        nj = JOBS_CAP;
    }
    for (i = 0; i < nj; i++) {
        printf(
            "%u %u %u %u %u %u\n",
            jobs[i].m0,
            jobs[i].n0,
            jobs[i].k0,
            jobs[i].m_t,
            jobs[i].n_t,
            jobs[i].k_t
        );
    }
    return 0;
}
