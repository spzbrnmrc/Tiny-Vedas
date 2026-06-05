/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

void vedas_printf(const char* fmt, ...);

int main() {

    vedas_printf("Hello, World\n");
    vedas_printf("Number is: %d\n", 1000);
    return 0;
}