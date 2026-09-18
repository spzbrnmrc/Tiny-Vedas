#include "Vgemm_top_tb.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vgemm_top_tb *top = new Vgemm_top_tb;
#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC *tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("gemm_top.vcd");
#endif
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
    delete top;
    return 0;
}
