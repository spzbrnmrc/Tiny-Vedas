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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - IDU0
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

module idu0 (

    /* Clock and Reset */
    input logic clk,
    input logic rstn,

    /* IFU Interface */
    input logic [INSTR_LEN-1:0] instr,
    input logic                 instr_valid,
    input logic [     XLEN-1:0] instr_tag,

    /* Control Signals */
    input logic pipe_stall,
    input logic pipe_flush,
    /* IDU1 Interface */
    output idu0_out_t idu0_out
);

  idu0_out_t   idu0_out_i;
  decode_out_t decode_out;

  /* Instantiate Decode Table */
  rv32im_decoder decode_inst (
      .i(instr),
      .o(decode_out)
  );



  assign idu0_out_i.instr = instr;
  assign idu0_out_i.instr_tag = instr_tag;
  assign idu0_out_i.rs1_addr = instr[19:15];
  assign idu0_out_i.rs2_addr = instr[24:20];

  assign idu0_out_i.imm = ({32{decode_out.imm20 & ~decode_out.pc}} & {instr[31:12], 12'h0}) |
                          ({32{decode_out.imm20 & decode_out.pc}} & {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'h0}) |
                          ({32{decode_out.imm12}} & {{20{instr[31]}}, instr[31:20]}) |
                          ({32{decode_out.condbr}} & {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}) |
                          ({32{decode_out.load}} & {{20{instr[31]}}, instr[31:20]}) |
                          ({32{decode_out.store}} & {{20{instr[31]}}, instr[31:25], instr[11:7]});

  /* imm_valid is high ONLY when the immediate is used in the register file path, for branch ops, is used in the PC path */
  assign idu0_out_i.imm_valid = (decode_out.imm20 & ~decode_out.jal) |
                                decode_out.imm12 |
                                decode_out.load |
                                decode_out.store;

  assign idu0_out_i.rd_addr = instr[11:7];
  assign idu0_out_i.shamt = instr[24:20];

  assign idu0_out_i.alu = decode_out.alu;
  assign idu0_out_i.rs1 = decode_out.rs1;
  assign idu0_out_i.rs2 = decode_out.rs2;
  assign idu0_out_i.imm12 = decode_out.imm12;
  assign idu0_out_i.rd = decode_out.rd;
  assign idu0_out_i.shimm5 = decode_out.shimm5;
  assign idu0_out_i.imm20 = decode_out.imm20;
  assign idu0_out_i.pc = decode_out.pc;
  assign idu0_out_i.load = decode_out.load;
  assign idu0_out_i.store = decode_out.store;
  assign idu0_out_i.lsu = decode_out.lsu;
  assign idu0_out_i.add = decode_out.add;
  assign idu0_out_i.sub = decode_out.sub;
  assign idu0_out_i.land = decode_out.land;
  assign idu0_out_i.lor = decode_out.lor;
  assign idu0_out_i.lxor = decode_out.lxor;
  assign idu0_out_i.sll = decode_out.sll;
  assign idu0_out_i.sra = decode_out.sra;
  assign idu0_out_i.srl = decode_out.srl;
  assign idu0_out_i.slt = decode_out.slt;
  assign idu0_out_i.unsign = decode_out.unsign;
  assign idu0_out_i.condbr = decode_out.condbr;
  assign idu0_out_i.beq = decode_out.beq;
  assign idu0_out_i.bne = decode_out.bne;
  assign idu0_out_i.bge = decode_out.bge;
  assign idu0_out_i.blt = decode_out.blt;
  assign idu0_out_i.jal = decode_out.jal;
  assign idu0_out_i.by = decode_out.by;
  assign idu0_out_i.half = decode_out.half;
  assign idu0_out_i.word = decode_out.word;
  assign idu0_out_i.mul = decode_out.mul;
  assign idu0_out_i.rs1_sign = decode_out.rs1_sign;
  assign idu0_out_i.rs2_sign = decode_out.rs2_sign;
  assign idu0_out_i.low = decode_out.low;
  assign idu0_out_i.div = decode_out.div;
  assign idu0_out_i.rem = decode_out.rem;
  assign idu0_out_i.nop = decode_out.nop;
  assign idu0_out_i.ecall = decode_out.ecall;
  assign idu0_out_i.legal = decode_out.legal;

  /* Output Flop */
  register_en_flush_sync_rstn #(
      .WIDTH($bits(idu0_out_t))
  ) idu0_out_flop_inst (
      .clk  (clk),
      .rstn (rstn),
      .din  (idu0_out_i),
      .dout (idu0_out),
      .en   (~pipe_stall),
      .flush(pipe_flush)
  );

endmodule
