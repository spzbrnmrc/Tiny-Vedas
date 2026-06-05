/*
 * Copyright (c) 2025 Siliscale Consulting, LLC
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdarg.h>
#include <stdio.h>

#define STR(x) #x
#define XSTR(s) STR(s)

#define MMIO_UART_ADDR 0x200000

void uart_write(char b) {
#ifdef TEST
  printf("%c", b);
#else
  int mmio_addr = MMIO_UART_ADDR;
  /* .insn s opcode, func3, rd, rs1, simm12 */
  asm("sb %0, 0(%1)" : : "r"(b), "r"(mmio_addr));
#endif
}

void intToStr(int N, char *str) {
  int i = 0;

  // Save the copy of the number for sign
  int sign = N;

  // If the number is negative, make it positive
  if (N < 0)
    N = -N;

  // Extract digits from the number and add them to the
  // string
  while (N > 0) {

    // Convert integer digit to character and store
    // it in the str
    str[i++] = N % 10 + '0';
    N /= 10;
  }

  // If the number was negative, add a minus sign to the
  // string
  if (sign < 0) {
    str[i++] = '-';
  }

  // Null-terminate the string
  str[i] = '\0';

  // Reverse the string to get the correct order
  for (int j = 0, k = i - 1; j < k; j++, k--) {
    char temp = str[j];
    str[j] = str[k];
    str[k] = temp;
  }
}

void vedas_printf(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);

  while (*fmt != '\0') {
    if (*fmt == '%') {
      if (*(fmt + 1) == 'd') {
        int i = va_arg(args, int);
        char s[12];

        intToStr(i, s);

        for (int j = 0; s[j] != '\0'; j++) {
          uart_write(s[j]);
        }
      } else if (*(fmt + 1) == 'c') {
        char c = (char)va_arg(args, int);
        uart_write(c);
      } else if (*(fmt + 1) == 's') {
        char *s = va_arg(args, char *);
        while (*s != '\0') {
          uart_write(*s);
          ++s;
        }
      }
      ++fmt;
    } else {
      uart_write(*fmt);
    }
    ++fmt;
  }

  va_end(args);
}