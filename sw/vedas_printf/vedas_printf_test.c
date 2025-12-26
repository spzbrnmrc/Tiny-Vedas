void vedas_printf(const char* fmt, ...);

int main() {

    vedas_printf("Hello, World\n");
    vedas_printf("Number is: %d\n", 1000);
    return 0;
}