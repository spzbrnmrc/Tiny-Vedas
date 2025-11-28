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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - IFU
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

module ifu (
    /* Clock and Reset */
    input logic            clk,
    input logic            rstn,
    input logic [XLEN-1:0] reset_vector,

    /* Instruction Memory Interface */
    output logic [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr,
    output logic                            instr_mem_addr_valid,
    output logic [                XLEN-1:0] instr_mem_tag_out,
    input  logic [     INSTR_MEM_WIDTH-1:0] instr_mem_rdata,
    input  logic                            instr_mem_rdata_valid,
    input  logic [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in,

    /* EXU -> IFU Interface */
    input logic [XLEN-1:0] pc_exu,
    input logic            pc_load,

    /* Control Signals */
    input  logic                 pipe_stall,
    output logic [INSTR_LEN-1:0] instr,
    output logic                 instr_valid,
    output logic [     XLEN-1:0] instr_tag
);

  logic [XLEN-1:0] pc_out;
  logic            pc_out_valid;

  assign instr_mem_addr = pc_out[INSTR_MEM_ADDR_WIDTH-1:0];  /* Crop the PC since the instr_mem_addr
                                                                is narrower than the PC */
  assign instr_mem_tag_out = pc_out;

  /* Instantiate the Program Counter */
  program_counter #(
      .PC_WIDTH  (XLEN),
      .INC_AMOUNT(INSTR_LEN_BYTES)
  ) pc_inst (
      .clk         (clk),
      .rstn        (rstn),
      .reset_vector(reset_vector),
      .load        (pc_load),
      .inc         (~pc_load),
      .stall       (pipe_stall),
      .pc_in       (pc_exu),
      .pc_out      (pc_out),
      .pc_out_valid(pc_out_valid)
  );

  assign instr_mem_addr_valid = pc_out_valid & ~pc_load;

  /* Generate the outputs */
  register_en_flush_sync_rstn #(
      .WIDTH(INSTR_LEN + 1 + XLEN)
  ) instr_dff_rst_inst (
      .clk  (clk),
      .rstn (rstn),
      .din  ({instr_mem_rdata_valid, instr_mem_rdata, instr_mem_tag_in}),
      .dout ({instr_valid, instr, instr_tag}),
      .en   (~pipe_stall),
      .flush(pc_load)
  );
endmodule
