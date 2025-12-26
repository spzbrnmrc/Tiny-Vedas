#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

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
        int n = floor(log10(i)) + 1;
        char *s;
        s = (char *)malloc(n + 1);

        intToStr(i, s);

        for (int j = 0; j < n; j++) {
          uart_write(s[j]);
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