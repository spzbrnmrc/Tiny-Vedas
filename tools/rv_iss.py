#!/usr/bin/env python3

# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

"""
RISC-V Instruction Set Simulator (RV32I)
Hardware verification ISS that generates execution traces
"""

import sys
import struct
import argparse
from typing import Dict, List, Tuple, Optional
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))
from gemm_ref import gemm_int8  # noqa: E402

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
    
    # v1 legal vtype: vma=1, vta=1, vsew=e32, vlmul=m1. Same as rtl/vector/vector_top.sv.
    VTYPE_LEGAL = 0x000000D0  # vma=1, vta=1, vsew=e32 (010), vlmul=m1
    VTYPE_VILL = 0x80000000
    CSR_VSTART = 0x008
    CSR_VL = 0xC20
    CSR_VTYPE = 0xC21
    CSR_VLENB = 0xC22

    def __init__(self, text_start: int, stack_base: int, stack_size: int,
                 eot_addr: int = 0x10000000, eot_size: int = 4,
                 gemm_addr: int = 0x00300000, gemm_size: int = 0x1000,
                 vlen: int = 0):
        self.regs = RegisterFile()
        self.mem = Memory()
        self.pc = text_start
        self.text_start = text_start
        self.stack_base = stack_base
        self.stack_size = stack_size
        self.eot_addr = eot_addr & 0xFFFFFFFF
        self.eot_size = max(1, eot_size)
        self.gemm_addr = gemm_addr & 0xFFFFFFFF
        self.gemm_size = max(1, gemm_size)
        self.vlen = int(vlen)
        self.vlenb = (self.vlen // 8) if self.vlen else 0
        self.vlmax = (self.vlen // 32) if self.vlen else 0
        self.vl = 0
        self.vtype = self.VTYPE_VILL if self.vlen else 0
        self.vstart = 0
        self.vregs = [[0] * (self.vlen // 32) for _ in range(32)] if self.vlen else []
        self.gemm_csr = {
            0x00: 0,
            0x04: 0,
            0x08: 0,
            0x0C: 0,
            0x10: 0,
            0x14: 0,
            0x18: 0,
            0x1C: 0,
        }

        # Initialize stack pointer
        self.regs.write(2, stack_base + stack_size)  # x2 is stack pointer

    def _gemm_hit(self, addr: int) -> bool:
        a = addr & 0xFFFFFFFF
        return self.gemm_addr <= a < (self.gemm_addr + self.gemm_size)

    def _run_gemm(self) -> None:
        base_a = self.gemm_csr[0x00] & 0xFFFFFFFF
        base_b = self.gemm_csr[0x04] & 0xFFFFFFFF
        base_c = self.gemm_csr[0x08] & 0xFFFFFFFF
        m = self.gemm_csr[0x0C] & 0xFFFFFFFF
        n = self.gemm_csr[0x10] & 0xFFFFFFFF
        k = self.gemm_csr[0x14] & 0xFFFFFFFF
        if m == 0 or n == 0 or k == 0:
            self.gemm_csr[0x1C] = 0x2  # done
            return
        a = [self.mem.read_byte(base_a + i) for i in range(m * k)]
        b = [self.mem.read_byte(base_b + i) for i in range(k * n)]
        c = gemm_int8(a, b, m, n, k)
        for i, val in enumerate(c):
            self.mem.write_word(base_c + 4 * i, val & 0xFFFFFFFF)
        self.gemm_csr[0x1C] = 0x2  # done, not busy
    
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

    def _vtype_legal(self, vtype: int) -> bool:
        return (vtype & 0xFFFFFFFF) == self.VTYPE_LEGAL

    def _apply_vset(self, rd: int, avl: int, req_vtype: int, keep_vl: bool) -> None:
        """RVV 1.0 vsetvl table. keep_vl is the rd==x0 && rs1==x0 case."""
        if not self._vtype_legal(req_vtype):
            self.vl = 0
            self.vtype = self.VTYPE_VILL
            self.vstart = 0
            if rd != 0:
                self.regs.write(rd, 0)
            return
        if keep_vl:
            vl = self.vl
        elif avl < self.vlmax:
            vl = avl
        else:
            vl = self.vlmax
        self.vl = vl & 0xFFFFFFFF
        self.vtype = self.VTYPE_LEGAL
        self.vstart = 0
        if rd != 0:
            self.regs.write(rd, self.vl)

    def _exec_csr(self, inst: int, rd: int, rs1: int, funct3: int, resources: List[str]) -> None:
        csr = (inst >> 20) & 0xFFF
        # v1: csrrs rd, csr, x0 of the four vector CSRs only.
        if self.vlen and funct3 == 2 and rs1 == 0:
            if csr == self.CSR_VL:
                val = self.vl
            elif csr == self.CSR_VTYPE:
                val = self.vtype
            elif csr == self.CSR_VLENB:
                val = self.vlenb
            elif csr == self.CSR_VSTART:
                val = self.vstart
            else:
                raise ValueError(f"Undecodeable CSR 0x{csr:03X} at PC 0x{self.pc:08X}")
            self.regs.write(rd, val)
            if rd != 0:
                resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X}")
            return
        if funct3 != 0:
            # Existing RV32IM images may contain unused SYSTEM encodings; skip.
            return

    def _exec_vector(self, inst: int, rd: int, rs1: int, rs2: int, funct3: int,
                     resources: List[str]) -> None:
        if not self.vlen:
            raise ValueError(f"Vector op 0x{inst:08X} with VLEN=0 at PC 0x{self.pc:08X}")
        if funct3 != 7:
            self._exec_valu(inst, rd, rs1, rs2, funct3)
            return
        if (inst >> 31) == 0:
            # vsetvli
            zimm = (inst >> 20) & 0x7FF
            rs1_is_x0 = rs1 == 0
            rd_is_x0 = rd == 0
            if rd_is_x0 and rs1_is_x0:
                self._apply_vset(rd, self.vl, zimm, keep_vl=True)
            elif (not rd_is_x0) and rs1_is_x0:
                self._apply_vset(rd, self.vlmax, zimm, keep_vl=False)
            else:
                self._apply_vset(rd, self.regs.read(rs1), zimm, keep_vl=False)
        elif (inst >> 30) == 3:
            # vsetivli: AVL is uimm, not the x0 table
            zimm = (inst >> 20) & 0x3FF
            uimm = (inst >> 15) & 0x1F
            self._apply_vset(rd, uimm, zimm, keep_vl=False)
        elif ((inst >> 25) & 0x7F) == 0x40:
            # vsetvl
            rs1_is_x0 = rs1 == 0
            rd_is_x0 = rd == 0
            req = self.regs.read(rs2)
            if rd_is_x0 and rs1_is_x0:
                self._apply_vset(rd, self.vl, req, keep_vl=True)
            elif (not rd_is_x0) and rs1_is_x0:
                self._apply_vset(rd, self.vlmax, req, keep_vl=False)
            else:
                self._apply_vset(rd, self.regs.read(rs1), req, keep_vl=False)
        else:
            raise ValueError(f"Undecodeable vset 0x{inst:08X} at PC 0x{self.pc:08X}")
        if rd != 0:
            resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X}")

    def _vmem_enc_ok(self, inst: int, funct3: int) -> bool:
        """Unmasked unit-stride e32: nf=0 mew=0 mop=00 vm=1 lumop/sumop=0 width=110."""
        return (
            self.vlen
            and funct3 == 6
            and ((inst >> 20) & 0xFFF) == 0x020
        )

    def _exec_vle32(self, rd: int, rs1: int) -> None:
        if self.vtype == self.VTYPE_VILL:
            return
        base = self.regs.read(rs1)
        for i in range(self.vl):
            self.vregs[rd][i] = self.mem.read_word(base + 4 * i) & 0xFFFFFFFF
        for i in range(self.vl, self.vlmax):
            self.vregs[rd][i] = 0xFFFFFFFF

    def _exec_vse32(self, vs3: int, rs1: int) -> None:
        if self.vtype == self.VTYPE_VILL or self.vl == 0:
            return
        base = self.regs.read(rs1)
        for i in range(self.vl):
            self.mem.write_word(base + 4 * i, self.vregs[vs3][i] & 0xFFFFFFFF)

    @staticmethod
    def _sext5(imm: int) -> int:
        imm &= 0x1F
        return (imm | 0xFFFFFFE0) if (imm & 0x10) else imm

    def _fill_tail(self, vd: int) -> None:
        for i in range(self.vl, self.vlmax):
            self.vregs[vd][i] = 0xFFFFFFFF

    @staticmethod
    def _to_signed(x: int) -> int:
        return x - 0x100000000 if x >= 0x80000000 else x

    @staticmethod
    def _valu_op(funct6: int, a: int, b: int) -> int:
        if funct6 == 0x00:
            return (a + b) & 0xFFFFFFFF
        if funct6 == 0x02:
            return (a - b) & 0xFFFFFFFF
        if funct6 == 0x03:
            return (b - a) & 0xFFFFFFFF
        if funct6 == 0x04:
            return a if a <= b else b
        if funct6 == 0x05:
            sa = RISC_V_ISS._to_signed(a)
            sb = RISC_V_ISS._to_signed(b)
            return a if sa <= sb else b
        if funct6 == 0x06:
            return a if a >= b else b
        if funct6 == 0x07:
            sa = RISC_V_ISS._to_signed(a)
            sb = RISC_V_ISS._to_signed(b)
            return a if sa >= sb else b
        if funct6 == 0x09:
            return (a & b) & 0xFFFFFFFF
        if funct6 == 0x0A:
            return (a | b) & 0xFFFFFFFF
        if funct6 == 0x0B:
            return (a ^ b) & 0xFFFFFFFF
        if funct6 == 0x17:
            return b & 0xFFFFFFFF
        sh = b & 31
        if funct6 == 0x25:
            return (a << sh) & 0xFFFFFFFF
        if funct6 == 0x28:
            return a >> sh
        if funct6 == 0x29:
            return (RISC_V_ISS._to_signed(a) >> sh) & 0xFFFFFFFF
        raise ValueError(f"Undecodeable valu funct6=0x{funct6:02X}")

    @staticmethod
    def _valu_cmp(funct6: int, a: int, b: int) -> bool:
        sa = RISC_V_ISS._to_signed(a)
        sb = RISC_V_ISS._to_signed(b)
        if funct6 == 0x18:
            return a == b
        if funct6 == 0x19:
            return a != b
        if funct6 == 0x1A:
            return a < b
        if funct6 == 0x1B:
            return sa < sb
        if funct6 == 0x1C:
            return a <= b
        if funct6 == 0x1D:
            return sa <= sb
        if funct6 == 0x1E:
            return a > b
        if funct6 == 0x1F:
            return sa > sb
        raise ValueError(f"Undecodeable valu compare funct6=0x{funct6:02X}")

    def _valu_src1(self, inst: int, rs1: int, funct3: int, funct6: int) -> int:
        if funct3 == 4:
            return self.regs.read(rs1) & 0xFFFFFFFF
        if funct3 == 3:
            imm = (inst >> 15) & 0x1F
            if funct6 in (0x25, 0x28, 0x29):
                return imm
            return self._sext5(imm) & 0xFFFFFFFF
        raise ValueError(f"Undecodeable valu funct3={funct3}")

    def _exec_valu(self, inst: int, rd: int, rs1: int, rs2: int, funct3: int) -> None:
        if self.vtype == self.VTYPE_VILL:
            return
        funct6 = (inst >> 26) & 0x3F
        vm = (inst >> 25) & 1
        vs2 = (inst >> 20) & 0x1F
        if not vm:
            raise ValueError(f"Masked valu 0x{inst:08X} at PC 0x{self.pc:08X}")
        legal_f3 = {
            0x00: (0, 3, 4),
            0x02: (0, 4),
            0x03: (3, 4),
            0x04: (0, 4),
            0x05: (0, 4),
            0x06: (0, 4),
            0x07: (0, 4),
            0x09: (0, 3, 4),
            0x0A: (0, 3, 4),
            0x0B: (0, 3, 4),
            0x17: (0, 3, 4),
            0x18: (0, 3, 4),
            0x19: (0, 3, 4),
            0x1A: (0, 4),
            0x1B: (0, 4),
            0x1C: (0, 3, 4),
            0x1D: (0, 3, 4),
            0x1E: (3, 4),
            0x1F: (3, 4),
            0x25: (0, 3, 4),
            0x28: (0, 3, 4),
            0x29: (0, 3, 4),
        }
        if funct6 not in legal_f3 or funct3 not in legal_f3[funct6]:
            raise ValueError(f"Undecodeable valu 0x{inst:08X} at PC 0x{self.pc:08X}")
        if funct6 == 0x17 and vs2 != 0:
            raise ValueError(f"Undecodeable vmv 0x{inst:08X} at PC 0x{self.pc:08X}")
        scalar = None if funct3 == 0 else self._valu_src1(inst, rs1, funct3, funct6)
        if 0x18 <= funct6 <= 0x1F:
            mask = 0
            for i in range(self.vl):
                a = self.vregs[vs2][i]
                b = self.vregs[rs1][i] if funct3 == 0 else scalar
                if self._valu_cmp(funct6, a, b):
                    mask |= 1 << i
            for i in range(self.vl, self.vlmax):
                mask |= 1 << i
            self.vregs[rd][0] = 0xFFFF0000 | (mask & 0xFFFF)
            for i in range(1, self.vlmax):
                self.vregs[rd][i] = 0xFFFFFFFF
            return
        dest = [0] * self.vlmax
        for i in range(self.vl):
            a = self.vregs[vs2][i]
            b = self.vregs[rs1][i] if funct3 == 0 else scalar
            dest[i] = self._valu_op(funct6, a, b)
        for i in range(self.vl):
            self.vregs[rd][i] = dest[i]
        self._fill_tail(rd)
    
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
        
        # SYSTEM (ECALL, EBREAK, CSR)
        if opcode == 0x73:
            if funct3 == 0:
                if imm == 0:  # ECALL
                    return "ecall"
                elif imm == 1:  # EBREAK
                    return "ebreak"
            csr = (inst >> 20) & 0xFFF
            csr_names = {
                self.CSR_VSTART: "vstart",
                self.CSR_VL: "vl",
                self.CSR_VTYPE: "vtype",
                self.CSR_VLENB: "vlenb",
            }
            name = csr_names.get(csr, f"0x{csr:03X}")
            if funct3 == 2 and rs1 == 0:
                return f"csrr {self.regs.get_name(rd)},{name}"
            return f"csr(0x{inst:08X})"

        # OP-V (vset* in v1)
        if opcode == 0x57:
            if funct3 == 7:
                if (inst >> 31) == 0:
                    return f"vsetvli {self.regs.get_name(rd)},{self.regs.get_name(rs1)},vtypei"
                if (inst >> 30) == 3:
                    uimm = (inst >> 15) & 0x1F
                    return f"vsetivli {self.regs.get_name(rd)},{uimm},vtypei"
                if ((inst >> 25) & 0x7F) == 0x40:
                    return (
                        f"vsetvl {self.regs.get_name(rd)},"
                        f"{self.regs.get_name(rs1)},{self.regs.get_name(rs2)}"
                    )
            funct6 = (inst >> 26) & 0x3F
            vs2 = (inst >> 20) & 0x1F
            uimm = (inst >> 15) & 0x1F
            simm = self._sext5(uimm)
            if funct6 == 0x00:
                if funct3 == 0:
                    return f"vadd.vv v{rd},v{vs2},v{rs1}"
                if funct3 == 4:
                    return f"vadd.vx v{rd},v{vs2},{self.regs.get_name(rs1)}"
                if funct3 == 3:
                    return f"vadd.vi v{rd},v{vs2},{simm}"
            if funct6 == 0x02:
                if funct3 == 0:
                    return f"vsub.vv v{rd},v{vs2},v{rs1}"
                if funct3 == 4:
                    return f"vsub.vx v{rd},v{vs2},{self.regs.get_name(rs1)}"
            if funct6 == 0x03:
                if funct3 == 4:
                    return f"vrsub.vx v{rd},v{vs2},{self.regs.get_name(rs1)}"
                if funct3 == 3:
                    return f"vrsub.vi v{rd},v{vs2},{simm}"
            names = {
                0x04: "vminu",
                0x05: "vmin",
                0x06: "vmaxu",
                0x07: "vmax",
                0x09: "vand",
                0x0A: "vor",
                0x0B: "vxor",
                0x18: "vmseq",
                0x19: "vmsne",
                0x1A: "vmsltu",
                0x1B: "vmslt",
                0x1C: "vmsleu",
                0x1D: "vmsle",
                0x1E: "vmsgtu",
                0x1F: "vmsgt",
                0x25: "vsll",
                0x28: "vsrl",
                0x29: "vsra",
            }
            if funct6 in names:
                op = names[funct6]
                if funct3 == 0:
                    return f"{op}.vv v{rd},v{vs2},v{rs1}"
                if funct3 == 4:
                    return f"{op}.vx v{rd},v{vs2},{self.regs.get_name(rs1)}"
                if funct3 == 3:
                    imm = uimm if funct6 in (0x25, 0x28, 0x29) else simm
                    return f"{op}.vi v{rd},v{vs2},{imm}"
            if funct6 == 0x17 and vs2 == 0:
                if funct3 == 0:
                    return f"vmv.v.v v{rd},v{rs1}"
                if funct3 == 4:
                    return f"vmv.v.x v{rd},{self.regs.get_name(rs1)}"
                if funct3 == 3:
                    return f"vmv.v.i v{rd},{simm}"
            return f"vec(0x{inst:08X})"

        if opcode == 0x07 and self._vmem_enc_ok(inst, funct3):
            return f"vle32.v v{rd},({self.regs.get_name(rs1)})"
        if opcode == 0x27 and self._vmem_enc_ok(inst, funct3):
            return f"vse32.v v{rd},({self.regs.get_name(rs1)})"
        
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

            if self._gemm_hit(addr):
                off = (addr - self.gemm_addr) & 0xFF
                off = off & ~3
                val = self.gemm_csr.get(off, 0) & 0xFFFFFFFF
            elif funct3 == 0:  # LB
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
            resources.append(f"{self.regs.get_name(rd)}=0x{self.regs.read(rd):08X} // Loading from 0x{addr:08X}")

        # Store
        elif opcode == 0x23:
            base = self.regs.read(rs1)
            addr = (base + imm) & 0xFFFFFFFF
            val = self.regs.read(rs2)

            if self._gemm_hit(addr):
                off = (addr - self.gemm_addr) & 0xFF
                off = off & ~3
                if funct3 == 2:  # SW
                    stored_val = val & 0xFFFFFFFF
                    self.gemm_csr[off] = stored_val
                    if off == 0x18 and (stored_val & 1):
                        self._run_gemm()
                    elif off == 0x18 and (stored_val & 2):
                        self.gemm_csr[0x1C] = 0
                elif funct3 == 0:
                    stored_val = val & 0xFF
                else:
                    stored_val = val & 0xFFFF
                resources.append(f"mem[0x{addr:08X}]=0x{stored_val:08X}")
            else:
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
            if self.eot_addr <= addr < (self.eot_addr + self.eot_size):
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
        
        # SYSTEM (ECALL, EBREAK, CSR reads)
        elif opcode == 0x73:
            if funct3 == 0:
                if imm == 0:  # ECALL
                    should_continue = True
                    resources.append("ecall")
                elif imm == 1:  # EBREAK
                    should_continue = True
                    resources.append("ebreak")
                else:
                    raise ValueError(
                        f"Invalid SYSTEM instruction: 0x{inst:08X} at PC 0x{self.pc:08X}"
                    )
            else:
                self._exec_csr(inst, rd, rs1, funct3, resources)

        # OP-V
        elif opcode == 0x57:
            self._exec_vector(inst, rd, rs1, rs2, funct3, resources)

        # Vector unit-stride load / store (LOAD-FP / STORE-FP encodings)
        elif opcode == 0x07:
            if not self._vmem_enc_ok(inst, funct3):
                raise ValueError(f"Undecodeable vle 0x{inst:08X} at PC 0x{self.pc:08X}")
            self._exec_vle32(rd, rs1)
        elif opcode == 0x27:
            if not self._vmem_enc_ok(inst, funct3):
                raise ValueError(f"Undecodeable vse 0x{inst:08X} at PC 0x{self.pc:08X}")
            self._exec_vse32(rd, rs1)
        
        # FENCE
        elif opcode == 0x0F:
            # FENCE is a NOP for our purposes
            pass
        
        # Invalid instruction. Vector / CSR paths raise in their helpers.
        # Scalar unknown stays a skip until the smoke list is grepped for padding.
        #else:
        #    raise ValueError(f"Invalid instruction: 0x{inst:08X} at PC 0x{self.pc:08X} (opcode: 0x{opcode:02X})")
        
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
            
            # Get entry point and text section base from ELF
            entry_point = elf.header['e_entry']
            
            # Load text section
            text_section = elf.get_section_by_name('.text')
            if text_section is None:
                raise ValueError("No .text section found in ELF file")
            
            text_section_addr = text_section['sh_addr']
            text_data = text_section.data()
            text_size = len(text_data)
            
            # Load text section into memory at its ELF base address (word-aligned array)
            self.mem.load_data(text_section_addr, text_data)
            
            # Load other sections (data, rodata, etc.)
            for section in elf.iter_sections():
                if section.name in ['.data', '.rodata', '.bss', '.sdata', ".init_array", ".fini_array"] and section.data_size > 0:
                    addr = section['sh_addr']
                    data = section.data()
                    self.mem.load_data(addr, data)

        # Entry point from command line (self.text_start) is >= text_section_addr
        # Since we loaded at text_section_addr, PC is simply the entry point
        self.pc = self.text_start
        
        # Text section bounds (where we actually loaded it - from ELF, not entry point)
        # This allows jumping backwards to instructions before the entry point
        text_start_addr = text_section_addr
        text_end_addr = text_section_addr + text_size
        
        # Execute instructions
        max_instructions = 20000000  # Pack loops at -O0 exceed 1M on large GEMMs
        instruction_count = 0

        with open(output_file, 'w') as trace_file:
            while instruction_count < max_instructions:
                # Check if PC is within text section bounds before fetching
                # Only execute instructions from the actual text section address range
                if self.pc < text_start_addr or self.pc >= text_end_addr:
                    # PC is outside the text section, stop execution
                    break

                # Fetch instruction
                if self.pc % 4 != 0:
                    raise ValueError(f"Misaligned PC: 0x{self.pc:08X}")

                # Save PC immediately after checking alignment (before fetching)
                instruction_pc = self.pc

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

                # Decode
                opcode, fields = self.decode_instruction(inst)

                # Disassemble
                disasm = self.disassemble(inst, fields)

                # Execute
                should_continue, resources = self.execute_instruction(inst, fields)

                # Generate trace line using the saved PC (before execution).
                # Skip empty retires (e.g. vset rd=x0) — RTL has no observe event.
                if resources:
                    resources_str = ";".join(resources)
                    trace_file.write(
                        f"0x{instruction_pc:08X};0x{inst:08X};{disasm};{resources_str}\n"
                    )

                if not should_continue:
                    break

                instruction_count += 1

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
    
    parser.add_argument(
        '--eot-addr',
        default='0x10000000',
        type=lambda x: int(x, 0),
        help='MMIO end-of-test base address (default: 0x10000000)'
    )
    parser.add_argument(
        '--eot-size',
        default='4',
        type=lambda x: int(x, 0),
        help='MMIO end-of-test region size in bytes (default: 4)'
    )
    
    parser.add_argument(
        '--gemm-addr',
        default='0x00300000',
        type=lambda x: int(x, 0),
        help='MMIO GEMM CSR base (default: 0x00300000)'
    )
    parser.add_argument(
        '--gemm-size',
        default='0x1000',
        type=lambda x: int(x, 0),
        help='MMIO GEMM CSR size (default: 0x1000)'
    )
    parser.add_argument(
        '--vlen',
        default=0,
        type=int,
        help='Vector register width in bits (0 = no vector)',
    )
    parser.add_argument(
        '--hw-config',
        default=None,
        help='HwConfig YAML; sets --vlen from vector.width_bits when enabled',
    )
    
    args = parser.parse_args()

    vlen = args.vlen
    if args.hw_config:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        from hw import load_hw_config  # noqa: WPS433
        hw = load_hw_config(args.hw_config)
        if hw.has_vector_unit:
            vlen = hw.vector.width_bits
    
    iss = RISC_V_ISS(
        args.text_start,
        args.stack_base,
        args.stack_size,
        eot_addr=args.eot_addr,
        eot_size=args.eot_size,
        gemm_addr=args.gemm_addr,
        gemm_size=args.gemm_size,
        vlen=vlen,
    )
    iss.run(args.elf_file, args.output, args.mem_file)


if __name__ == '__main__':
    main()

