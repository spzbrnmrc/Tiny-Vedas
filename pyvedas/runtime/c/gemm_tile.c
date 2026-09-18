/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Keep in lockstep with pyvedas/jit/memory/gemm_tiles.py.
 * Host unit tests only — the core ELF does not link this file. Tile
 * selection is done by the JIT and baked into generated.c.
 */

#include "gemm_tile.h"

static size_t min_sz(size_t a, size_t b) {
    return a < b ? a : b;
}

static uint64_t tile_scratch_bytes(
    size_t m_t,
    size_t n_t,
    size_t k_t,
    size_t n,
    size_t k
) {
    uint64_t pack = (uint64_t)m_t * (uint64_t)k_t + (uint64_t)k_t * (uint64_t)n_t;
    int direct = (k_t == k) && (n_t == n);
    uint64_t tmp = direct ? 0ull : (uint64_t)m_t * (uint64_t)n_t * 4ull;
    uint64_t pad = direct ? 0ull : (uint64_t)PYVEDAS_GEMM_ALIGN_PAD;
    return pack + tmp + pad;
}

/* Match Python dim_candidates without a 12KiB stack array (core stack is 4KiB). */
static size_t cand_count(size_t dim, size_t align) {
    size_t n_mult;

    if (dim == 0 || align == 0) {
        return 0;
    }
    if (dim <= align) {
        return 1;
    }
    n_mult = dim / align;
    if (dim == n_mult * align) {
        return n_mult;
    }
    return n_mult + 1;
}

static size_t cand_at(size_t dim, size_t align, size_t idx) {
    size_t n_mult;

    if (dim <= align) {
        return dim;
    }
    n_mult = dim / align;
    if (idx < n_mult) {
        return (idx + 1) * align;
    }
    return dim;
}

size_t pyvedas_gemm_scratch_cap = PYVEDAS_GEMM_SCRATCH_BYTES;

void pyvedas_gemm_set_scratch_cap(size_t bytes) {
    if (bytes > (size_t)PYVEDAS_GEMM_SCRATCH_BYTES) {
        bytes = (size_t)PYVEDAS_GEMM_SCRATCH_BYTES;
    }
    pyvedas_gemm_scratch_cap = bytes;
}

size_t pyvedas_gemm_scratch_budget(size_t live_bytes) {
    size_t used;
    size_t left;

    used = (size_t)PYVEDAS_DCCM_RESERVE_BYTES + live_bytes;
    if ((size_t)PYVEDAS_DCCM_BYTES > used) {
        left = (size_t)PYVEDAS_DCCM_BYTES - used;
    } else {
        left = 0;
    }
    if (left > pyvedas_gemm_scratch_cap) {
        left = pyvedas_gemm_scratch_cap;
    }
    return left;
}

int pyvedas_gemm_choose_tile(
    size_t m,
    size_t n,
    size_t k,
    size_t scratch_bytes,
    size_t *m_t,
    size_t *n_t,
    size_t *k_t
) {
    size_t nm, nn, nk, i, j, t;
    int found = 0;
    uint64_t best_work = 0;
    size_t best_kt = 0, best_nt = 0, best_mt = 0;

    if (m == 0 || n == 0 || k == 0 || m_t == NULL || n_t == NULL || k_t == NULL) {
        return 0;
    }

    nm = cand_count(m, PYVEDAS_GEMM_PE_DIM);
    nn = cand_count(n, PYVEDAS_GEMM_PE_DIM);
    nk = cand_count(k, PYVEDAS_GEMM_K_TILE);

    for (t = 0; t < nk; t++) {
        size_t kt = cand_at(k, PYVEDAS_GEMM_K_TILE, t);
        for (j = 0; j < nn; j++) {
            size_t nt = cand_at(n, PYVEDAS_GEMM_PE_DIM, j);
            for (i = 0; i < nm; i++) {
                size_t mt = cand_at(m, PYVEDAS_GEMM_PE_DIM, i);
                uint64_t need = tile_scratch_bytes(mt, nt, kt, n, k);
                uint64_t work;
                if (need > (uint64_t)scratch_bytes) {
                    continue;
                }
                work = (uint64_t)mt * (uint64_t)nt * (uint64_t)kt;
                if (!found || work > best_work ||
                    (work == best_work && kt > best_kt) ||
                    (work == best_work && kt == best_kt && nt > best_nt) ||
                    (work == best_work && kt == best_kt && nt == best_nt &&
                     mt > best_mt)) {
                    found = 1;
                    best_work = work;
                    best_kt = kt;
                    best_nt = nt;
                    best_mt = mt;
                }
            }
        }
    }

    if (!found) {
        return 0;
    }
    *m_t = best_mt;
    *n_t = best_nt;
    *k_t = best_kt;
    return 1;
}

size_t pyvedas_gemm_plan(
    size_t m,
    size_t n,
    size_t k,
    size_t scratch_bytes,
    pyvedas_gemm_job_t *jobs,
    size_t jobs_cap
) {
    size_t mt, nt, kt;
    size_t m0, n0, k0;
    size_t count = 0;

    if (!pyvedas_gemm_choose_tile(m, n, k, scratch_bytes, &mt, &nt, &kt)) {
        return 0;
    }

    for (m0 = 0; m0 < m; m0 += mt) {
        size_t mti = min_sz(mt, m - m0);
        for (n0 = 0; n0 < n; n0 += nt) {
            size_t nti = min_sz(nt, n - n0);
            for (k0 = 0; k0 < k; k0 += kt) {
                size_t kti = min_sz(kt, k - k0);
                if (jobs != NULL && count < jobs_cap) {
                    jobs[count].m0 = (uint32_t)m0;
                    jobs[count].n0 = (uint32_t)n0;
                    jobs[count].k0 = (uint32_t)k0;
                    jobs[count].m_t = (uint32_t)mti;
                    jobs[count].n_t = (uint32_t)nti;
                    jobs[count].k_t = (uint32_t)kti;
                }
                count++;
            }
        }
    }
    return count;
}
