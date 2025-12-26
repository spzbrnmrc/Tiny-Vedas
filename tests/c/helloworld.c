extern void vedas_printf(const char *format, ...);
extern void eot_sequence();

int main() {
    vedas_printf("Hello, World!\n");
    vedas_printf("Number is %d\n", 100);
    eot_sequence();
    return 0;
}