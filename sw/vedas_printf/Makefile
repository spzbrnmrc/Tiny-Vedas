test:
	gcc -DTEST vedas_printf_test.c vedas_printf.c -lm -o vedas_printf_test

object:
	riscv64-unknown-elf-gcc -c -O3 -fno-builtin-printf -fno-common -falign-functions=4 -march=rv32imf -mabi=ilp32 -lm vedas_printf.c -o vedas_printf.o

clean:
	rm vedas_printf_test
	rm *.o
	rm dump