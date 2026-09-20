/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include "pyvedas.h"

void pyvedas_aten_arange(int32_t *out, size_t end) {
    size_t i;
    for (i = 0; i < end; i++) {
        out[i] = (int32_t)i;
    }
}
