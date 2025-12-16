#!/usr/bin/env python3
"""
RISC-V Instruction Set Simulator (RV32I)
Hardware verification ISS that generates execution traces
"""

import sys
import struct
import argparse
from typing import Dict, List, Tuple, Optional

try:
    from elftools.elf.elffile import ELFFile
    from elftools.elf.sections import Section
except ImportError:
    print("Error: pyelftools not installed. Install with: pip install pyelftools")
    sys.exit(1)


class RegisterFile:
    """32 RISC-V registers (x0-x31)"""
    def __init__(self):
        self.regs = [0] * 32
        # x0 is hardwired to 0
    
    def read(self, reg: int) -> int:
        """Read register value (x0 always returns 0)"""
        if reg == 0:
            return 0
        return self.regs[reg] & 0xFFFFFFFF
    
    def write(self, reg: int, value: int):
        """Write register value (x0 writes are ignored)"""
        if reg != 0:
            self.regs[reg] = value & 0xFFFFFFFF
    
    def get_name(self, reg: int) -> str:
        """Get register name (x0-x31)"""
        return f"x{reg}"


class Memory:
    """Byte-addressable memory"""
    def __init__(self):
        self.mem: Dict[int, int] = {}
    
    def read_byte(self, addr: int) -> int:
        """Read byte from memory"""
        return self.mem.get(addr, 0) & 0xFF
    
    def write_byte(self, addr: int, value: int):
        """Write byte to memory"""
        self.mem[addr] = value & 0xFF
    
    def read_word(self, addr: int) -> int:
        """Read 32-bit word from memory (little-endian)"""
        val = 0
        for i in range(4):
            val |= (self.read_byte(addr + i) << (i * 8))
        return val & 0xFFFFFFFF
    
    def write_word(self, addr: int, value: int):
        """Write 32-bit word to memory (little-endian)"""
        for i in range(4):
            self.write_byte(addr + i, (value >> (i * 8)) & 0xFF)
    
    def read_half(self, addr: int) -> int:
        """Read 16-bit halfword from memory (little-endian)"""
        val = (self.read_byte(addr) | (self.read_byte(addr + 1) << 8)) & 0xFFFF
        return val
    
    def write_half(self, addr: int, value: int):
        """Write 16-bit halfword to memory (little-endian)"""
        self.write_byte(addr, value & 0xFF)
        self.write_byte(addr + 1, (value >> 8) & 0xFF)
    
    def load_data(self, addr: int, data: bytes):
        """Load data into memory starting at address"""
        for i, byte in enumerate(data):
            self.write_byte(addr + i, byte)


class RISC_V_ISS:
    """RISC-V Instruction Set Simulator"""
    
    # Termination address: writing to this address terminates simulation
    TERMINATION_ADDR = 0x10000000
    
    def __init__(self, text_start: int, stack_base: int, stack_size: int):
        self.regs = RegisterFile()
        self.mem = Memory()
        self.pc = text_start
        self.text_start = text_start
        self.stack_base = stack_base
        self.stack_size = stack_size
        
        # Initialize stack pointer
        self.regs.write(2, stack_base + stack_size)  # x2 is stack pointer
    
    def sign_extend(self, value: int, bits: int) -> int:
        """Sign extend value to 32 bits"""
        sign_bit = 1 << (bits - 1)
        if value & sign_bit:
            return value | (~((1 << bits) - 1) & 0xFFFFFFFF)
        return value & ((1 << bits) - 1)
    
    def to_signed32(self, value: int) -> int:
        """Convert 32-bit unsigned value to signed integer"""
        value = value & 0xFFFFFFFF
        if value & 0x80000000:
            return value - 0x100000000
        return value
    
    def decode_instruction(self, inst: int) -> Tuple[str, Dict]:
        """Decode RISC-V instruction and return (opcode, fields)"""
        opcode = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        funct3 = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        funct7 = (inst >> 25) & 0x7F
        
        fields = {
            'opcode': opcode,
            'rd': rd,
            'rs1': rs1,
            'rs2': rs2,
            'funct3': funct3,
            'funct7': funct7,
            'inst': inst
        }
        
        # Extract immediates based on instruction type
        if opcode == 0x37:  # LUI
            imm = (inst >> 12) << 12
            fields['imm'] = imm
        elif opcode == 0x17:  # AUIPC
            imm = (inst >> 12) << 12
            fields['imm'] = imm
        elif opcode == 0x6F:  # JAL
            imm = ((inst >> 31) & 0x1) << 20
            imm |= ((inst >> 21) & 0x3FF) << 1
            imm |= ((inst >> 20) & 0x1) << 11
            imm |= ((inst >> 12) & 0xFF) << 12
            fields['imm'] = self.sign_extend(imm, 21)
        elif opcode == 0x67:  # JALR
            imm = (inst >> 20) & 0xFFF
            fields['imm'] = self.sign_extend(imm, 12)
        elif opcode == 0x63:  # Branch
            imm = ((inst >> 31) & 0x1) << 12
            imm |= ((inst >> 7) & 0x1) << 11
            imm |= ((inst >> 25) & 0x3F) << 5
            imm |= ((inst >> 8) & 0xF) << 1
            fields['imm'] = self.sign_extend(imm, 13)
        elif opcode == 0x03:  # Load
            imm = (inst >> 20) & 0xFFF
            fields['imm'] = self.sign_extend(imm, 12)
        elif opcode == 0x23:  # Store
            imm = ((inst >> 25) & 0x7F) << 5
            imm |= ((inst >> 7) & 0x1F)
            fields['imm'] = self.sign_extend(imm, 12)
        elif opcode in [0x13, 0x73]:  # I-type (ALU immediate, SYSTEM)
            imm = (inst >> 20) & 0xFFF
            fields['imm'] = self.sign_extend(imm, 12)
        else:
            fields['imm'] = 0
        
        return opcode, fields
    
    def disassemble(self, inst: int, fields: Dict) -> str:
        """Disassemble instruction to assembly string"""
        opcode = fields['opcode']
        rd = fields['rd']
        rs1 = fields['rs1']
        rs2 = fields['rs2']
        funct3 = fields['funct3']
        funct7 = fields['funct7']
        imm = fields.get('imm', 0)
        
        # Format immediate as hex
        def fmt_imm(val):
            # Show as hex, using 8 digits for negative values
            if val < 0:
                return f"0x{val & 0xFFFFFFFF:08X}"
            else:
                return f"0x{val:X}"
        
        # LUI
        if opcode == 0x37:
            return f"lui {self.regs.get_name(rd)},{fmt_imm(imm >> 12)}"
        
        # AUIPC
        if opcode == 0x17:
            return f"auipc {self.regs.get_name(rd)},{fmt_imm(imm >> 12)}"
        
        # JAL
        if opcode == 0x6F:
            return f"jal {self.regs.get_name(rd)},{fmt_imm(imm)}"
        
        # JALR
        if opcode == 0x67:
            return f"jalr {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
        
        # Branch
        if opcode == 0x63:
            branch_ops = {0: 'beq', 1: 'bne', 4: 'blt', 5: 'bge', 6: 'bltu', 7: 'bgeu'}
            op = branch_ops.get(funct3, 'unknown')
            return f"{op} {self.regs.get_name(rs1)},{self.regs.get_name(rs2)},{fmt_imm(imm)}"
        
        # Load
        if opcode == 0x03:
            load_ops = {0: 'lb', 1: 'lh', 2: 'lw', 4: 'lbu', 5: 'lhu'}
            op = load_ops.get(funct3, 'unknown')
            return f"{op} {self.regs.get_name(rd)},{fmt_imm(imm)}({self.regs.get_name(rs1)})"
        
        # Store
        if opcode == 0x23:
            store_ops = {0: 'sb', 1: 'sh', 2: 'sw'}
            op = store_ops.get(funct3, 'unknown')
            return f"{op} {self.regs.get_name(rs2)},{fmt_imm(imm)}({self.regs.get_name(rs1)})"
        
        # ALU immediate
        if opcode == 0x13:
            if funct3 == 0:  # ADDI
                return f"addi {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
            elif funct3 == 1:  # SLLI
                shamt = imm & 0x1F
                return f"slli {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{shamt}"
            elif funct3 == 2:  # SLTI
                return f"slti {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
            elif funct3 == 3:  # SLTIU
                return f"sltiu {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
            elif funct3 == 4:  # XORI
                return f"xori {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
            elif funct3 == 5:
                shamt = imm & 0x1F
                if funct7 == 0:  # SRLI
                    return f"srli {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{shamt}"
                elif funct7 == 0x20:  # SRAI
                    return f"srai {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{shamt}"
            elif funct3 == 6:  # ORI
                return f"ori {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
            elif funct3 == 7:  # ANDI
                return f"andi {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{fmt_imm(imm)}"
        
        # ALU register
        if opcode == 0x33:
            if funct3 == 0:
                if funct7 == 0:  # ADD
                    return f"add {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x20:  # SUB
                    return f"sub {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # MUL (M extension)
                    return f"mul {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 1:
                if funct7 == 0:  # SLL
                    return f"sll {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # MULH (M extension)
                    return f"mulh {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 2:
                if funct7 == 0:  # SLT
                    return f"slt {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # MULHSU (M extension)
                    return f"mulhsu {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 3:
                if funct7 == 0:  # SLTU
                    return f"sltu {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # MULHU (M extension)
                    return f"mulhu {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 4:
                if funct7 == 0:  # XOR
                    return f"xor {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # DIV (M extension)
                    return f"div {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 5:
                if funct7 == 0:  # SRL
                    return f"srl {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x20:  # SRA
                    return f"sra {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # DIVU (M extension)
                    return f"divu {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 6:
                if funct7 == 0:  # OR
                    return f"or {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # REM (M extension)
                    return f"rem {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
            elif funct3 == 7:
                if funct7 == 0:  # AND
                    return f"and {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                elif funct7 == 0x01:  # REMU (M extension)
                    return f"remu {self.regs.get_name(rd)},{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
        
        # SYSTEM (ECALL, EBREAK)
        if opcode == 0x73:
            if funct3 == 0:
                if imm == 0:  # ECALL
                    return "ecall"
                elif imm == 1:  # EBREAK
                    return "ebreak"
        
        # FENCE
        if opcode == 0x0F:
            return "fence"
        
        return f"unknown(0x{inst:08X})"
    
    def execute_instruction(self, inst: int, fields: Dict) -> Tuple[bool, List[str]]:
        """Execute instruction and return (should_continue, resources_touched)"""
        opcode = fields['opcode']
        rd = fields['rd']
        rs1 = fields['rs1']
        rs2 = fields['rs2']
        funct3 = fields['funct3']
        funct7 = fields['funct7']
        imm = fields.get('imm', 0)
        
        resources = []
        should_continue = True
        
        # LUI
        if opcode == 0x37:
            self.regs.write(rd, imm)
            resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X}")
        
        # AUIPC
        elif opcode == 0x17:
            result = (self.pc + imm) & 0xFFFFFFFF
            self.regs.write(rd, result)
            resources.append(f"{self.regs.get_name(rd)}=0x{result:08X}")
        
        # JAL
        elif opcode == 0x6F:
            next_pc = self.pc + 4
            self.regs.write(rd, next_pc)
            new_pc = (self.pc + imm) & 0xFFFFFFFF
            self.pc = new_pc
            # Show register write even for x0 (trace format)
            resources.append(f"{self.regs.get_name(rd)}=0x{next_pc:08X}")
            resources.append(f"pc=0x{new_pc:08X}")
            return should_continue, resources
        
        # JALR
        elif opcode == 0x67:
            next_pc = self.pc + 4
            base = self.regs.read(rs1)
            target = (base + imm) & 0xFFFFFFFE  # Clear LSB
            self.regs.write(rd, next_pc)
            self.pc = target
            # Show register write even for x0 (trace format)
            resources.append(f"{self.regs.get_name(rd)}=0x{next_pc:08X}")
            resources.append(f"pc=0x{target:08X}")
            return should_continue, resources
        
        # Branch
        elif opcode == 0x63:
            val1 = self.regs.read(rs1)
            val2 = self.regs.read(rs2)
            taken = False
            
            if funct3 == 0:  # BEQ
                taken = (val1 == val2)
            elif funct3 == 1:  # BNE
                taken = (val1 != val2)
            elif funct3 == 4:  # BLT (signed)
                val1_signed = self.to_signed32(val1)
                val2_signed = self.to_signed32(val2)
                taken = (val1_signed < val2_signed)
            elif funct3 == 5:  # BGE (signed)
                val1_signed = self.to_signed32(val1)
                val2_signed = self.to_signed32(val2)
                taken = (val1_signed >= val2_signed)
            elif funct3 == 6:  # BLTU (unsigned)
                taken = (val1 < val2)
            elif funct3 == 7:  # BGEU (unsigned)
                taken = (val1 >= val2)
            
            if taken:
                self.pc = (self.pc + imm) & 0xFFFFFFFF
                resources.append(f"taken=true")
                resources.append(f"pc=0x{self.pc:08X}")
            else:
                # Branch not taken: increment PC by 4 to next instruction
                self.pc = (self.pc + 4) & 0xFFFFFFFF
                resources.append(f"taken=false")
            
            return should_continue, resources
        
        # Load
        elif opcode == 0x03:
            base = self.regs.read(rs1)
            addr = (base + imm) & 0xFFFFFFFF
            
            if funct3 == 0:  # LB
                val = self.mem.read_byte(addr)
                val = self.sign_extend(val, 8)
            elif funct3 == 1:  # LH
                val = self.mem.read_half(addr)
                val = self.sign_extend(val, 16)
            elif funct3 == 2:  # LW
                val = self.mem.read_word(addr)
            elif funct3 == 4:  # LBU
                val = self.mem.read_byte(addr)
            elif funct3 == 5:  # LHU
                val = self.mem.read_half(addr)
            else:
                val = 0
            
            self.regs.write(rd, val)
            resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X}")
        
        # Store
        elif opcode == 0x23:
            base = self.regs.read(rs1)
            addr = (base + imm) & 0xFFFFFFFF
            val = self.regs.read(rs2)
            
            if funct3 == 0:  # SB
                self.mem.write_byte(addr, val)
                stored_val = val & 0xFF
                resources.append(f"mem[0x{addr:08X}]=0x{stored_val:08X}")
            elif funct3 == 1:  # SH
                self.mem.write_half(addr, val)
                stored_val = val & 0xFFFF
                resources.append(f"mem[0x{addr:08X}]=0x{stored_val:08X}")
            elif funct3 == 2:  # SW
                self.mem.write_word(addr, val)
                stored_val = val & 0xFFFFFFFF
                resources.append(f"mem[0x{addr:08X}]=0x{stored_val:08X}")
            
            # Check for termination address after executing the store
            if addr == self.TERMINATION_ADDR:
                should_continue = False
        
        # ALU immediate
        elif opcode == 0x13:
            rs1_val = self.regs.read(rs1)
            result = 0
            
            if funct3 == 0:  # ADDI
                result = (rs1_val + imm) & 0xFFFFFFFF
            elif funct3 == 1:  # SLLI
                shamt = imm & 0x1F
                result = (rs1_val << shamt) & 0xFFFFFFFF
            elif funct3 == 2:  # SLTI
                # Compare as signed: rs1 (signed) < imm (signed, sign-extended from 12 bits)
                rs1_signed = self.to_signed32(rs1_val)
                imm_signed = self.to_signed32(imm)
                result = 1 if rs1_signed < imm_signed else 0
            elif funct3 == 3:  # SLTIU
                result = 1 if (rs1_val < (imm & 0xFFFFFFFF)) else 0
            elif funct3 == 4:  # XORI
                result = (rs1_val ^ imm) & 0xFFFFFFFF
            elif funct3 == 5:
                shamt = imm & 0x1F
                if funct7 == 0:  # SRLI
                    result = (rs1_val >> shamt) & 0xFFFFFFFF
                elif funct7 == 0x20:  # SRAI
                    # Arithmetic right shift: convert to signed, shift (preserves sign), mask to 32 bits
                    rs1_signed = self.to_signed32(rs1_val)
                    shifted = rs1_signed >> shamt
                    # Convert back to unsigned 32-bit representation (two's complement)
                    result = shifted % 0x100000000
            elif funct3 == 6:  # ORI
                result = (rs1_val | imm) & 0xFFFFFFFF
            elif funct3 == 7:  # ANDI
                result = (rs1_val & imm) & 0xFFFFFFFF
            
            self.regs.write(rd, result)
            resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X}")
        
        # ALU register
        elif opcode == 0x33:
            rs1_val = self.regs.read(rs1)
            rs2_val = self.regs.read(rs2)
            result = 0
            
            if funct3 == 0:
                if funct7 == 0:  # ADD
                    result = (rs1_val + rs2_val) & 0xFFFFFFFF
                elif funct7 == 0x20:  # SUB
                    result = (rs1_val - rs2_val) & 0xFFFFFFFF
                elif funct7 == 0x01:  # MUL (M extension)
                    # MUL: lower 32 bits of multiplication
                    product = (rs1_val * rs2_val) & 0xFFFFFFFF
                    result = product
            elif funct3 == 1:
                if funct7 == 0:  # SLL
                    shamt = rs2_val & 0x1F
                    result = (rs1_val << shamt) & 0xFFFFFFFF
                elif funct7 == 0x01:  # MULH (M extension)
                    # MULH: upper 32 bits of signed×signed multiplication
                    rs1_signed = self.to_signed32(rs1_val)
                    rs2_signed = self.to_signed32(rs2_val)
                    product = rs1_signed * rs2_signed
                    # Get upper 32 bits (sign-extend to 64 bits, then shift right 32)
                    result = (product >> 32) & 0xFFFFFFFF
            elif funct3 == 2:
                if funct7 == 0:  # SLT
                    # Compare as signed: rs1 (signed) < rs2 (signed)
                    rs1_signed = self.to_signed32(rs1_val)
                    rs2_signed = self.to_signed32(rs2_val)
                    result = 1 if rs1_signed < rs2_signed else 0
                elif funct7 == 0x01:  # MULHSU (M extension)
                    # MULHSU: upper 32 bits of signed×unsigned multiplication
                    rs1_signed = self.to_signed32(rs1_val)
                    product = rs1_signed * rs2_val
                    # Get upper 32 bits
                    result = (product >> 32) & 0xFFFFFFFF
            elif funct3 == 3:
                if funct7 == 0:  # SLTU
                    result = 1 if (rs1_val < rs2_val) else 0
                elif funct7 == 0x01:  # MULHU (M extension)
                    # MULHU: upper 32 bits of unsigned×unsigned multiplication
                    product = rs1_val * rs2_val
                    # Get upper 32 bits
                    result = (product >> 32) & 0xFFFFFFFF
            elif funct3 == 4:
                if funct7 == 0:  # XOR
                    result = (rs1_val ^ rs2_val) & 0xFFFFFFFF
                elif funct7 == 0x01:  # DIV (M extension)
                    # DIV: signed division (rounds toward zero)
                    rs1_signed = self.to_signed32(rs1_val)
                    rs2_signed = self.to_signed32(rs2_val)
                    if rs2_signed == 0:
                        # Division by zero: return all 1s
                        result = 0xFFFFFFFF
                    elif rs1_signed == -0x80000000 and rs2_signed == -1:
                        # Overflow: most negative / -1
                        result = 0x80000000  # Equal to dividend
                    else:
                        # Normal division (rounds toward zero)
                        # Python's // rounds toward -infinity, so we need truncation toward zero
                        # For truncation: if signs differ and there's a remainder, round up
                        quotient = rs1_signed // rs2_signed
                        # If signs differ and there's a remainder, we need to round toward zero (up)
                        if (rs1_signed < 0) != (rs2_signed < 0) and (rs1_signed % rs2_signed != 0):
                            quotient += 1
                        result = quotient % 0x100000000
            elif funct3 == 5:
                if funct7 == 0:  # SRL
                    shamt = rs2_val & 0x1F
                    result = (rs1_val >> shamt) & 0xFFFFFFFF
                elif funct7 == 0x20:  # SRA
                    # Arithmetic right shift: convert to signed, shift (preserves sign), mask to 32 bits
                    shamt = rs2_val & 0x1F
                    rs1_signed = self.to_signed32(rs1_val)
                    shifted = rs1_signed >> shamt
                    # Convert back to unsigned 32-bit representation (two's complement)
                    result = shifted % 0x100000000
                elif funct7 == 0x01:  # DIVU (M extension)
                    # DIVU: unsigned division
                    if rs2_val == 0:
                        # Division by zero: return all 1s
                        result = 0xFFFFFFFF
                    else:
                        result = (rs1_val // rs2_val) & 0xFFFFFFFF
            elif funct3 == 6:
                if funct7 == 0:  # OR
                    result = (rs1_val | rs2_val) & 0xFFFFFFFF
                elif funct7 == 0x01:  # REM (M extension)
                    # REM: signed remainder (sign of result = sign of dividend)
                    rs1_signed = self.to_signed32(rs1_val)
                    rs2_signed = self.to_signed32(rs2_val)
                    if rs2_signed == 0:
                        # Division by zero: remainder equals dividend
                        result = rs1_val
                    elif rs1_signed == -0x80000000 and rs2_signed == -1:
                        # Overflow: remainder is 0
                        result = 0
                    else:
                        # Normal remainder: compute using truncating division
                        # remainder = dividend - quotient * divisor
                        # where quotient rounds toward zero
                        quotient = rs1_signed // rs2_signed
                        # If signs differ and there's a remainder, adjust quotient for truncation
                        if (rs1_signed < 0) != (rs2_signed < 0) and (rs1_signed % rs2_signed != 0):
                            quotient += 1
                        remainder = rs1_signed - quotient * rs2_signed
                        result = remainder % 0x100000000
            elif funct3 == 7:
                if funct7 == 0:  # AND
                    result = (rs1_val & rs2_val) & 0xFFFFFFFF
                elif funct7 == 0x01:  # REMU (M extension)
                    # REMU: unsigned remainder
                    if rs2_val == 0:
                        # Division by zero: remainder equals dividend
                        result = rs1_val
                    else:
                        result = (rs1_val % rs2_val) & 0xFFFFFFFF
            
            self.regs.write(rd, result)
            resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X}")
        
        # SYSTEM (ECALL, EBREAK)
        elif opcode == 0x73:
            if funct3 == 0:
                if imm == 0:  # ECALL
                    should_continue = False
                    resources.append("ecall")
                elif imm == 1:  # EBREAK
                    should_continue = False
                    resources.append("ebreak")
        
        # FENCE
        elif opcode == 0x0F:
            # FENCE is a NOP for our purposes
            pass
        
        # Update PC (unless it was modified by branch/jump)
        if opcode not in [0x6F, 0x67, 0x63]:
            self.pc = (self.pc + 4) & 0xFFFFFFFF
        
        return should_continue, resources
    
    def load_hex_file(self, hex_file: str, base_addr: int = 0):
        """Load hex file into memory starting at base address.
        
        Hex file format: one 32-bit word per line (8 hex digits, no 0x prefix)
        Words are stored as little-endian bytes in memory.
        """
        with open(hex_file, 'r') as f:
            addr = base_addr
            for line in f:
                line = line.strip()
                if not line:
                    continue
                # Parse hex value (8 hex digits)
                word = int(line, 16) & 0xFFFFFFFF
                # Store as little-endian bytes
                self.mem.write_word(addr, word)
                addr += 4
    
    def run(self, elf_file: str, output_file: str, hex_file: Optional[str] = None):
        """Load ELF and execute instructions"""
        # Load hex file first (preload data memory)
        if hex_file:
            self.load_hex_file(hex_file, base_addr=0)
        
        # Load ELF file
        text_size = 0
        with open(elf_file, 'rb') as f:
            elf = ELFFile(f)
            
            # Load text section
            text_section = elf.get_section_by_name('.text')
            if text_section is None:
                raise ValueError("No .text section found in ELF file")
            
            text_data = text_section.data()
            text_size = len(text_data)
            self.mem.load_data(self.text_start, text_data)
            
            # Load other sections (data, rodata, etc.)
            for section in elf.iter_sections():
                if section.name in ['.data', '.rodata', '.bss'] and section.data_size > 0:
                    addr = section['sh_addr']
                    data = section.data()
                    self.mem.load_data(addr, data)
        
        # Calculate text section end address
        text_end = self.text_start + text_size
        
        # Execute instructions
        trace_lines = []
        max_instructions = 1000000  # Safety limit
        instruction_count = 0
        
        while instruction_count < max_instructions:
            # Check if PC is within text section bounds before fetching
            if self.pc < self.text_start or self.pc >= text_end:
                # PC is outside the loaded text section, stop execution
                break
            
            # Fetch instruction
            if self.pc % 4 != 0:
                raise ValueError(f"Misaligned PC: 0x{self.pc:08X}")
            
            inst = self.mem.read_word(self.pc)
            
            # Check for invalid instruction (all zeros or all ones) - but only warn if within bounds
            if inst == 0 or inst == 0xFFFFFFFF:
                # This might be padding or end of program, silently stop
                break
            
            # Check for NOP (ADDI x0, x0, 0 = 0x00000013)
            # NOPs don't touch microarchitectural state, so skip tracing
            if inst == 0x00000013:
                # Execute NOP (just updates PC)
                opcode, fields = self.decode_instruction(inst)
                should_continue, _ = self.execute_instruction(inst, fields)
                if not should_continue:
                    break
                instruction_count += 1
                continue
            
            # Save PC before execution (for trace output)
            instruction_pc = self.pc
            
            # Decode
            opcode, fields = self.decode_instruction(inst)
            
            # Disassemble
            disasm = self.disassemble(inst, fields)
            
            # Execute
            should_continue, resources = self.execute_instruction(inst, fields)
            
            # Generate trace line using the saved PC (before execution)
            resources_str = ";".join(resources) if resources else ""
            trace_line = f"0x{instruction_pc:08X};0x{inst:08X};{disasm};{resources_str}"
            trace_lines.append(trace_line)
            
            if not should_continue:
                break
            
            instruction_count += 1
        
        # Write trace file
        with open(output_file, 'w') as f:
            f.write('\n'.join(trace_lines))

def main():
    parser = argparse.ArgumentParser(
        description='RISC-V Instruction Set Simulator (RV32I)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s program.elf 0x100000 0x7FFFF000 0x1000
  %(prog)s program.elf 0x100000 0x7FFFF000 0x1000 -o trace.log
        '''
    )
    
    parser.add_argument(
        'elf_file',
        metavar='ELF_FILE',
        help='ELF file to execute'
    )
    
    parser.add_argument(
        'text_start',
        metavar='TEXT_START',
        type=lambda x: int(x, 16),
        help='Start address of text section (hex, e.g., 0x100000)'
    )
    
    parser.add_argument(
        'stack_base',
        metavar='STACK_BASE',
        type=lambda x: int(x, 16),
        help='Stack base address (hex, e.g., 0x7FFFF000)'
    )
    
    parser.add_argument(
        'stack_size',
        metavar='STACK_SIZE',
        type=lambda x: int(x, 16),
        help='Stack size in bytes (hex, e.g., 0x1000)'
    )
    
    parser.add_argument(
        '-o', '--output',
        default='iss.log',
        metavar='OUTPUT_FILE',
        help='Output trace file (default: iss.log)'
    )
    
    parser.add_argument(
        '-m', '--mem-file',
        default=None,
        metavar='HEX_FILE',
        help='Hex file to preload data memory (one 32-bit word per line, starting at address 0x0)'
    )
    
    args = parser.parse_args()
    
    iss = RISC_V_ISS(args.text_start, args.stack_base, args.stack_size)
    iss.run(args.elf_file, args.output, args.mem_file)


if __name__ == '__main__':
    main()

