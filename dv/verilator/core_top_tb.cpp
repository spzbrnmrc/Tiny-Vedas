/*
MIT License

Copyright (c) 2025 Siliscale Consulting LLC

https://siliscale.com

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without
limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

*/

#include "Vcore_top_tb.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

int main(int argc, char **argv, char **env) {
    Verilated::commandArgs(argc, argv);
    Vcore_top_tb* top = new Vcore_top_tb;
#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("core_top.vcd");
#endif

    printf("****** START of CORE TOP SIM ****** \n");

    while (!Verilated::gotFinish()) {
        top->eval();
#if VM_TRACE
        tfp->dump(Verilated::time());
#endif
        Verilated::timeInc(1);
    }
#if VM_TRACE
    tfp->close();
#endif
    printf("****** END of CORE TOP SIM ****** \n");
    delete top;
    return 0;
}