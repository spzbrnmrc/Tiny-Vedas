# Tiny Vedas - RISC-V RV32IM Processor

A complete, open-source implementation of a RISC-V RV32IM processor written in SystemVerilog. Tiny Vedas is a 4-stage pipelined processor with full RV32IM instruction set support, hazard handling, and comprehensive verification.

It is used as a reference for a [free course on RISC-V Processor Design](https://youtu.be/izPdo7n1u1I).

## Features

### Architecture
- **ISA**: RISC-V RV32IM (32-bit integer + multiply/divide)
- **Pipeline**: 4-stage pipeline (IFU → IDU0 → IDU1 → EXU)
- **Data Width**: 32-bit (XLEN = 32)
- **Memory**: Harvard architecture with separate instruction and data memories
- **Reset Vector**: Configurable (default: 0x80000000)

### Instruction Set Support
- **Arithmetic**: ADD, SUB, ADDI, LUI, AUIPC
- **Logical**: AND, OR, XOR, ANDI, ORI, XORI
- **Shifts**: SLL, SRL, SRA, SLLI, SRLI, SRAI
- **Comparison**: SLT, SLTU, SLTI, SLTIU
- **Branches**: BEQ, BNE, BLT, BGE, BLTU, BGEU
- **Jumps**: JAL, JALR
- **Memory**: LB, LH, LW, LBU, LHU, SB, SH, SW
- **Multiply/Divide**: MUL, MULH, MULHU, MULHSU, DIV, DIVU, REM, REMU

### Advanced Features
- **Data Hazard Resolution**: Register forwarding from EXU to IDU1
- **Control Hazard Handling**: Pipeline flush on branches
- **Multi-cycle Operations**: Pipelined multiplier and divider
- **Unaligned Memory Access**: Support for byte and half-word aligned loads/stores
- **Memory Forwarding**: Store-to-load forwarding for performance

## Project Structure

```
tiny-vedas/
├── rtl/                    # RTL design files
│   ├── core_top.sv        # Top-level processor module
│   ├── core_top.flist     # File list for synthesis
│   ├── ifu/               # Instruction fetch unit
│   │   └── ifu.sv         # IFU implementation
│   ├── idu/               # Instruction decode units
│   │   ├── idu0.sv        # Decode stage 0
│   │   ├── idu1.sv        # Decode stage 1
│   │   ├── reg_file.sv    # Register file
│   │   ├── decode.sv      # Auto-generated decode logic
│   │   └── decode         # Decode table specification
│   ├── exu/               # Execute unit
│   │   ├── exu.sv         # Execute unit top-level
│   │   ├── alu.sv         # Arithmetic logic unit
│   │   ├── mul.sv         # Multiplier unit
│   │   ├── div.sv         # Divider unit
│   │   └── lsu.sv         # Load/store unit
│   ├── include/           # Global definitions
│   │   ├── global.svh     # Global parameters
│   │   └── types.svh      # Type definitions
│   └── lib/               # Utility modules
│       ├── mem_lib.sv     # Memory modules
│       └── beh_lib.sv     # Behavioral models
├── tests/                 # Test programs
│   ├── asm/              # Assembly test programs
│   ├── c/                # C program tests
│   └── raw/              # Raw binary tests
├── dv/                    # Design verification
│   ├── sv/               # SystemVerilog testbenches
│   │   ├── core_top_tb.sv # Main testbench
│   │   └── lsu_tb.sv      # LSU testbench
│   └── verilator/        # Verilator simulation files
├── tools/                 # Development utilities
│   ├── dec_table_gen.py  # Decode table generator
│   ├── sim_manager.py    # Simulation manager
│   └── riscv_sim         # RISC-V simulator
├── SVLib/                 # SystemVerilog library
├── docs/                  # Documentation and Slides for the course
├── Makefile              # Build and simulation targets
└── LICENSE               # Apache 2.0 license
```

## Quick Start

### Prerequisites
- **SystemVerilog Simulator**: Verilator (recommended) or Xilinx Vivado
- **RISC-V Toolchain**: GCC with RISC-V target
- **Python 3**: For build scripts
- **Ubuntu 20.04+**: Tested platform

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/siliscale/Tiny-Vedas.git
   cd Tiny-Vedas
   ```

2. **Install dependencies**
   ```bash
   # Install Verilator
   sudo apt-get install verilator
   
   # Install RISC-V toolchain
   sudo apt-get install gcc-riscv64-linux-gnu
   
   # Install Python dependencies
   pip install -r requirements.txt
   ```

3. **Build and run simulation**
   ```bash
   # Run core simulation
   make core_top_sim
   
   # Run specific tests
   cd tests/asm
   make basic_alu_r
   ```

## Simulation

### Core Simulation
```bash
make core_top_sim
```
This runs the main testbench with Verilator, executing test programs and generating execution traces.

### Individual Unit Tests
```bash
# Test load/store unit
make lsu_sim

# Test specific assembly programs
cd tests/asm
make basic_alu_r    # Test ALU register operations
make basic_mul      # Test multiplication
make basic_branch   # Test branch instructions
```

### C Program Tests
```bash
cd tests/c
make helloworld     # Compile and run C program
```

## Configuration

### Memory Configuration
- **Instruction Memory**: 1KB (1024 words)
- **Data Memory**: 1KB (1024 words)
- **Stack Pointer**: Configurable initial value (default: 0x80000000)

### Pipeline Configuration
- **Stages**: 4-stage pipeline
- **Forwarding**: Full forwarding from EXU to IDU1
- **Stalling**: Multi-cycle operation support

## Verification

### Test Coverage
- **Unit Tests**: Individual component verification
- **Integration Tests**: Full pipeline verification
- **Instruction Tests**: Complete RV32IM instruction set coverage
- **Hazard Tests**: Data and control hazard scenarios

### Test Results
Simulation results are logged to:
- `rtl.log`: Instruction execution trace
- `console.log`: Program output
- Waveform files: For detailed timing analysis

## Synthesis

### FPGA Synthesis
```bash
# Generate decode tables
make decodes

# Synthesize with Vivado
make vivado_synth
```

### ASIC Synthesis
The design is synthesizable with standard ASIC tools. Use `rtl/core_top.flist` as the file list.

## Performance

### Pipeline Performance
- **CPI**: ~1.0 for most workloads
- **Branch Penalty**: 1 cycle for taken branches
- **Memory Latency**: 1 cycle for aligned accesses

### Resource Utilization
- **Registers**: ~2000 flip-flops
- **LUTs**: ~5000 (FPGA estimate)
- **Memory**: 2KB total (1KB instruction + 1KB data)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

### Development Guidelines
- Follow SystemVerilog coding standards
- Add comprehensive tests for new features
- Update documentation for API changes
- Ensure all tests pass before submitting

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

## Performance Scoreboard

|    Benchmark     |  IPC   |
|:----------------:|:------:|
| c.helloworld     | 0.5612 |
| elf.dhrystone    | 0.4478 |
