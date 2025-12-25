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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - IDU1
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

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

module idu1 #(
    parameter logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h80000000
) (
    input logic clk,
    input logic rstn,

    /* IDU0 -> IDU1 Interface */
    input idu0_out_t idu0_out,

    /* IDU1 -> EXU Interface */
    output idu1_out_t idu1_out,

    /* Control Signals */
    output logic                           pipe_stall,
    input  logic                           pipe_flush,
    /* EXU -> IDU1 (WB) Interface */
    input  logic [               XLEN-1:0] exu_wb_data,
    input  logic [REG_FILE_ADDR_WIDTH-1:0] exu_wb_rd_addr,
    input  logic                           exu_wb_rd_wr_en,
    input  logic                           exu_mul_busy,
    input  logic                           exu_div_busy,
    input  logic                           exu_lsu_busy,
    input  logic                           exu_lsu_stall
);

  idu1_out_t idu1_out_i;
  idu1_out_t idu1_out_before_fwd;
  logic [XLEN-1:0] rs1_data, rs2_data;
  last_issued_instr_t last_issued_instr;
  idu1_out_t idu1_out_gated;

  /* Instantiate Register file */
  reg_file #(
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) reg_file_i (
      .clk      (clk),
      .rstn     (rstn),
      .rs1_addr (idu0_out.rs1_addr),
      .rs2_addr (idu0_out.rs2_addr),
      .rs1_rd_en(idu0_out.rs1 & idu0_out.legal),
      .rs2_rd_en(idu0_out.rs2 & idu0_out.legal),
      .rs1_data (rs1_data),
      .rs2_data (rs2_data),
      .rd_addr  (exu_wb_rd_addr),
      .rd_data  (exu_wb_data),
      .rd_wr_en (exu_wb_rd_wr_en)
  );

  assign idu1_out_i.instr = idu0_out.instr;
  assign idu1_out_i.instr_tag = idu0_out.instr_tag;
  assign idu1_out_i.imm = idu0_out.imm;
  assign idu1_out_i.rd_addr = idu0_out.rd_addr;
  assign idu1_out_i.shamt = idu0_out.shamt;
  assign idu1_out_i.imm_valid = idu0_out.imm_valid;

  assign idu1_out_i.rs1_addr = idu0_out.rs1_addr;
  assign idu1_out_i.rs2_addr = idu0_out.rs2_addr;

  /* WB to IDU1 forwarding */
  assign idu1_out_i.rs1_data = ((exu_wb_rd_addr == idu0_out.rs1_addr) & idu0_out.rs1 & exu_wb_rd_wr_en) ? exu_wb_data : rs1_data;
  assign idu1_out_i.rs2_data = ((exu_wb_rd_addr == idu0_out.rs2_addr) & idu0_out.rs2 & exu_wb_rd_wr_en) ? exu_wb_data : rs2_data;

  assign idu1_out_i.alu = idu0_out.alu;
  assign idu1_out_i.rs1 = idu0_out.rs1;
  assign idu1_out_i.rs2 = idu0_out.rs2;
  assign idu1_out_i.imm12 = idu0_out.imm12;
  assign idu1_out_i.rd = idu0_out.rd;
  assign idu1_out_i.shimm5 = idu0_out.shimm5;
  assign idu1_out_i.imm20 = idu0_out.imm20;
  assign idu1_out_i.pc = idu0_out.pc;
  assign idu1_out_i.load = idu0_out.load;
  assign idu1_out_i.store = idu0_out.store;
  assign idu1_out_i.lsu = idu0_out.lsu;
  assign idu1_out_i.add = idu0_out.add;
  assign idu1_out_i.sub = idu0_out.sub;
  assign idu1_out_i.land = idu0_out.land;
  assign idu1_out_i.lor = idu0_out.lor;
  assign idu1_out_i.lxor = idu0_out.lxor;
  assign idu1_out_i.sll = idu0_out.sll;
  assign idu1_out_i.sra = idu0_out.sra;
  assign idu1_out_i.srl = idu0_out.srl;
  assign idu1_out_i.slt = idu0_out.slt;
  assign idu1_out_i.unsign = idu0_out.unsign;
  assign idu1_out_i.condbr = idu0_out.condbr;
  assign idu1_out_i.beq = idu0_out.beq;
  assign idu1_out_i.bne = idu0_out.bne;
  assign idu1_out_i.bge = idu0_out.bge;
  assign idu1_out_i.blt = idu0_out.blt;
  assign idu1_out_i.jal = idu0_out.jal;
  assign idu1_out_i.by = idu0_out.by;
  assign idu1_out_i.half = idu0_out.half;
  assign idu1_out_i.word = idu0_out.word;
  assign idu1_out_i.mul = idu0_out.mul;
  assign idu1_out_i.rs1_sign = idu0_out.rs1_sign;
  assign idu1_out_i.rs2_sign = idu0_out.rs2_sign;
  assign idu1_out_i.low = idu0_out.low;
  assign idu1_out_i.div = idu0_out.div;
  assign idu1_out_i.rem = idu0_out.rem;
  assign idu1_out_i.nop = idu0_out.nop;
  assign idu1_out_i.ecall = idu0_out.ecall;
  assign idu1_out_i.legal = idu0_out.legal;

  register_en_flush_sync_rstn #(
      .WIDTH($bits(idu1_out_t))
  ) idu1_out_reg (
      .clk  (clk),
      .rstn (rstn),
      .din  (idu1_out_i),
      .dout (idu1_out_before_fwd),
      .en   (~pipe_stall),
      .flush(pipe_flush)
  );

  register_en_flush_sync_rstn #(
      .WIDTH($bits(last_issued_instr_t))
  ) last_issued_instr_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
        idu1_out_before_fwd.instr,
        idu1_out_before_fwd.instr_tag,
        idu1_out_before_fwd.rs1_addr,
        idu1_out_before_fwd.rs2_addr,
        idu1_out_before_fwd.rd_addr,
        idu1_out_before_fwd.mul,
        idu1_out_before_fwd.alu,
        idu1_out_before_fwd.div,
        (idu1_out_before_fwd.load | idu1_out_before_fwd.store)
      }),
      .dout(last_issued_instr),
      .en(~pipe_stall),
      .flush(pipe_flush)
  );

  /* Check if I had any updates to a register that moved past the PRF query stage while I was stalled */
  logic [XLEN-1:0] stall_rs1_fwd_data, stall_rs2_fwd_data;
  logic stall_rs1_fwd_data_val, stall_rs2_fwd_data_val;

  /* WB to EXU forwarding */
  always_comb begin : operand_forwarding
    idu1_out_gated = idu1_out_before_fwd;

    /* RS1 */
    if (idu1_out_before_fwd.rs1 & (exu_wb_rd_addr == idu1_out_before_fwd.rs1_addr)) begin
      idu1_out_gated.rs1_data = exu_wb_data;
    end

    if (stall_rs1_fwd_data_val) idu1_out_gated.rs1_data = stall_rs1_fwd_data;

    /* RS2 */
    if (idu1_out_before_fwd.rs2 & (exu_wb_rd_addr == idu1_out_before_fwd.rs2_addr)) begin
      idu1_out_gated.rs2_data = exu_wb_data;
    end

    if (stall_rs2_fwd_data_val) idu1_out_gated.rs2_data = stall_rs2_fwd_data;

  end

  /* Manage The pipe_stall signal 
    We stall the pipeline in the following conditions:
    1. The instruction executing is a multiply operation and the coming instruction is not a multiply operation
    2. The instruction executing is a mulitply operation and the coming instruction is a multiply operation that depends on the result of the previous multiply operation (to leverage the pipelined multiply unit)
    3. The instruction executing is a divide operation (it's a blocking operation, so no pipelining)
  */
  always_comb begin : pipe_stall_management
    pipe_stall = 1'b0;
    if (last_issued_instr.mul & ~idu1_out_gated.mul & idu1_out_gated.legal & ~idu1_out_gated.nop) begin
      pipe_stall = exu_mul_busy;
    end
    else if (last_issued_instr.mul & idu1_out_gated.mul & ((last_issued_instr.rd_addr == idu1_out_gated.rs1_addr) | (last_issued_instr.rd_addr == idu1_out_gated.rs2_addr)) & idu1_out_gated.legal & ~idu1_out_gated.nop) begin
      pipe_stall = exu_mul_busy;
    end else if (last_issued_instr.div) begin
      pipe_stall = exu_div_busy;
    end else if (last_issued_instr.lsu & idu1_out_gated.legal & ~idu1_out_gated.nop) begin /* Always stall LSU operations */
      pipe_stall = exu_lsu_busy;
    end
    pipe_stall |= exu_lsu_stall;
  end

  always_comb begin : pipe_stall_output
    idu1_out = idu1_out_gated;
    idu1_out.legal = idu1_out_gated.legal & ~pipe_stall;
  end

endmodule
