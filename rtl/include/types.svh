///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
// 
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
// 
//        http://www.apache.org/licenses/LICENSE-2.0
// 
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.
///////////////////////////////////////////////////////////////////////////////
//           _____          
//          /\    \         
//         /::\    \        
//        /::::\    \       
//       /::::::\    \      
//      /:::/\:::\    \     
//     /:::/__\:::\    \            Vendor      : Siliscale
//     \:::\   \:::\    \           Version     : 2025.1
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Types
//  /\   \:::\   \:::\    \ 
// /::\   \:::\   \:::\____\
// \:::\   \:::\   \::/    /
//  \:::\   \:::\   \/____/ 
//   \:::\   \:::\    \     
//    \:::\   \:::\____\    
//     \:::\  /:::/    /    
//      \:::\/:::/    /     
//       \::::::/    /      
//        \::::/    /       
//         \::/    /        
//          \/____/         
///////////////////////////////////////////////////////////////////////////////

`ifndef TYPES_SVH
`define TYPES_SVH

typedef struct packed {

  logic [31:0]             instr;
  logic [XLEN-1:0]         instr_tag;
  logic [4:0]              rs1_addr;
  logic [4:0]              rs2_addr;
  logic [XLEN-1:0]         imm;
  logic                    imm_valid;
  logic [4:0]              rd_addr;
  logic [$clog2(XLEN)-1:0] shamt;

  /* Automatically generated */
  logic alu;
  logic rs1;
  logic rs2;
  logic imm12;
  logic rd;
  logic shimm5;
  logic imm20;
  logic pc;
  logic load;
  logic store;
  logic lsu;
  logic add;
  logic sub;
  logic land;
  logic lor;
  logic lxor;
  logic sll;
  logic sra;
  logic srl;
  logic slt;
  logic unsign;
  logic condbr;
  logic beq;
  logic bne;
  logic bge;
  logic blt;
  logic jal;
  logic by;
  logic half;
  logic word;
  logic mul;
  logic rs1_sign;
  logic rs2_sign;
  logic low;
  logic div;
  logic rem;
  logic nop;
  logic ecall;
  logic legal;
} idu0_out_t;

typedef struct packed {

  logic [31:0]             instr;
  logic [XLEN-1:0]         instr_tag;
  logic [XLEN-1:0]         rs1_data;
  logic [XLEN-1:0]         rs2_data;
  logic [4:0]              rs1_addr;
  logic [4:0]              rs2_addr;
  logic [XLEN-1:0]         imm;
  logic                    imm_valid;
  logic [4:0]              rd_addr;
  logic [$clog2(XLEN)-1:0] shamt;

  /* Automatically generated */
  logic alu;
  logic rs1;
  logic rs2;
  logic imm12;
  logic rd;
  logic shimm5;
  logic imm20;
  logic pc;
  logic load;
  logic store;
  logic lsu;
  logic add;
  logic sub;
  logic land;
  logic lor;
  logic lxor;
  logic sll;
  logic sra;
  logic srl;
  logic slt;
  logic unsign;
  logic condbr;
  logic beq;
  logic bne;
  logic bge;
  logic blt;
  logic jal;
  logic by;
  logic half;
  logic word;
  logic mul;
  logic rs1_sign;
  logic rs2_sign;
  logic low;
  logic div;
  logic rem;
  logic nop;
  logic ecall;
  logic legal;
} idu1_out_t;

typedef struct packed {
  logic [31:0] instr;
  logic [XLEN-1:0] instr_tag;
  logic [4:0] rs1_addr;
  logic [4:0] rs2_addr;
  logic [4:0] rd_addr;
  logic mul;
  logic alu;
  logic div;
  logic load;
  logic store;
} last_issued_instr_t;

typedef enum logic [2:0] {
  LSU_IDLE,
  LSU_LOAD_1,
  LSU_LOAD_2,
  LSU_DONE
} lsu_state_t;

`ifndef SYNTHESIS
/* Simulation retire events exported from core_top (one struct per issue lane). */
typedef struct packed {
  logic reg_wr;
  logic reg_wr_jal;
  logic br_taken;
  logic br_not_taken;
  logic mem_store;
  logic mem_store_unaligned;
  logic ecall;
  logic [XLEN-1:0] wb_instr_tag;
  logic [INSTR_LEN-1:0] wb_instr;
  logic [REG_FILE_ADDR_WIDTH-1:0] wb_rd_addr;
  logic [XLEN-1:0] wb_data;
  logic [XLEN-1:0] wb_pc;
  logic [XLEN-1:0] br_taken_instr_tag;
  logic [INSTR_LEN-1:0] br_taken_instr;
  logic [XLEN-1:0] br_taken_pc;
  logic [XLEN-1:0] br_not_taken_instr_tag;
  logic [INSTR_LEN-1:0] br_not_taken_instr;
  logic [XLEN-1:0] mem_store_instr_tag;
  logic [INSTR_LEN-1:0] mem_store_instr;
  logic [XLEN-1:0] mem_store_addr;
  logic [XLEN-1:0] mem_store_wdata;
  logic [XLEN-1:0] mem_store_unaligned_instr_tag;
  logic [INSTR_LEN-1:0] mem_store_unaligned_instr;
  logic [XLEN-1:0] mem_store_unaligned_addr;
  logic [XLEN-1:0] mem_store_unaligned_wdata;
  logic [XLEN-1:0] ecall_instr_tag;
  logic [INSTR_LEN-1:0] ecall_instr;
} core_debug_lane_t;
`endif

`endif
