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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - LSU
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

`timescale 1ns / 1ps

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

module lsu (
    input logic clk,
    input logic rstn,

    /* LSU Control */
    input  idu1_out_t lsu_ctrl,
    output logic      lsu_stall,
    output logic      lsu_busy,

    /* DEBUG */
    output logic [XLEN-1:0] instr_tag_out,
    output logic [    31:0] instr_out,

    /* LSU WB Data */
    output logic [XLEN-1:0] lsu_wb_data,
    output logic [     4:0] lsu_wb_rd_addr,
    output logic            lsu_wb_rd_wr_en,

    /* LSU DCCM Interface */
    output logic [XLEN-1:0] lsu_dccm_raddr,
    output logic            lsu_dccm_rvalid_in,
    input  logic [XLEN-1:0] lsu_dccm_rdata,
    input  logic            lsu_dccm_rvalid_out,
    output logic [XLEN-1:0] lsu_dccm_waddr,
    output logic            lsu_dccm_wen,
    output logic [XLEN-1:0] lsu_dccm_wdata
);

  logic dc1_by, dc1_half, dc1_word, dc1_load, dc1_store, dc1_unsign, dc1_legal;
  logic lsu_stall_q;
  logic dc1_lsu_valid;
  logic dc1_unaligned_addr;
  logic [XLEN-1:0] dc1_rs1_data, dc1_rs2_data, dc1_imm;
  logic [XLEN-1:0] dc1_computed_addr;
  logic [     4:0] dc1_rd_addr;
  logic            dc1_store_needs_load;
  logic            dc1_store_forward;
  logic [XLEN-1:0] dc1_forward_value;
  // DC2 signals
  logic dc2_by, dc2_half, dc2_word, dc2_load, dc2_store, dc2_unsign, dc2_legal;
  logic            dc2_lsu_valid;
  logic            dc2_unaligned_addr;
  logic [XLEN-1:0] dc2_computed_addr;
  logic [XLEN-1:0] dc2_load_buffer;
  logic [     4:0] dc2_rd_addr;
  logic [XLEN-1:0] dc2_rs2_data;
  logic            dc2_store_needs_load;
  logic            dc2_store_forward;
  logic [XLEN-1:0] dc2_forward_value;
  logic            dc2_store_forward_next;
  logic [XLEN-1:0] dc2_forward_value_next;
  // DC3 signals
  logic dc3_by, dc3_half, dc3_word, dc3_load, dc3_store, dc3_unsign, dc3_legal;
  logic                    dc3_unaligned_addr;
  logic [        XLEN-1:0] dc3_computed_addr;
  logic [        XLEN-1:0] dc3_load_buffer;
  logic [        XLEN-1:0] dc3_wb_data;
  logic [        XLEN-1:0] dc3_wb_data_mask;
  logic [        XLEN-1:0] dc3_wb_sext_mask;
  logic [             4:0] dc3_rd_addr;
  logic [$clog2(XLEN)-1:0] dc3_shamt;
  logic [             2:0] dc3_shamt_by;
  logic [        XLEN-1:0] dc3_rs2_data;

  logic [        XLEN-1:0] dc1_lsu_instr_tag_out;
  logic [            31:0] dc1_lsu_instr_out;

  logic [        XLEN-1:0] dc2_lsu_instr_tag_out;
  logic [            31:0] dc2_lsu_instr_out;

  logic [        XLEN-1:0] dc3_lsu_instr_tag_out;
  logic [            31:0] dc3_lsu_instr_out;
  logic [        XLEN-1:0] dc3_store_buffer;
  logic                    dc3_store_forward;
  logic [        XLEN-1:0] dc3_forward_value;
  /* ***** DC1 ***** */

  /* LSU Control Flops */
  register_sync_rstn #(
      .WIDTH(7)
  ) lsu_ctrl_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
        lsu_ctrl.by,
        lsu_ctrl.half,
        lsu_ctrl.word,
        lsu_ctrl.load,
        lsu_ctrl.store,
        lsu_ctrl.unsign,
        lsu_ctrl.legal
      }),
      .dout({dc1_by, dc1_half, dc1_word, dc1_load, dc1_store, dc1_unsign, dc1_legal})
  );

  /* LSU Data Flops */
  register_sync_rstn #(
      .WIDTH($bits({lsu_ctrl.rs1_data, lsu_ctrl.rs2_data, lsu_ctrl.imm, lsu_ctrl.rd_addr}))
  ) lsu_data_reg (
      .clk (clk),
      .rstn(rstn),
      .din ({lsu_ctrl.rs1_data, lsu_ctrl.rs2_data, lsu_ctrl.imm, lsu_ctrl.rd_addr}),
      .dout({dc1_rs1_data, dc1_rs2_data, dc1_imm, dc1_rd_addr})
  );

  register_sync_rstn #(
      .WIDTH(XLEN)
  ) lsu_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .din (lsu_ctrl.instr_tag),
      .dout(dc1_lsu_instr_tag_out)
  );

  register_sync_rstn #(
      .WIDTH(32)
  ) lsu_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .din (lsu_ctrl.instr),
      .dout(dc1_lsu_instr_out)
  );
  assign dc1_lsu_valid = dc1_legal & (dc1_load | dc1_store);
  assign dc1_computed_addr = dc1_rs1_data + {{XLEN - 12{dc1_imm[11]}}, dc1_imm[11:0]};

  /* LSU Unaligned Address Check */
  assign dc1_unaligned_addr = lsu_stall_q ? 'b0 : (|dc1_computed_addr[1:0] & dc1_word) | (&dc1_computed_addr[1:0] & dc1_half);
  assign dc1_store_needs_load = dc1_store & (dc1_by | dc1_half | dc1_word & dc1_unaligned_addr);

  assign dc1_store_forward = ((dc1_store | dc1_load) & dc1_legal) & (dc2_store & dc2_legal) & (lsu_dccm_waddr[XLEN-1:0] == {dc1_computed_addr[XLEN-1:2], 2'b00});
  assign dc1_forward_value = lsu_dccm_wdata;

  /* ****** DC2 ***** */
  register_sync_rstn #(
      .WIDTH($bits(
          {
            dc2_by,
            dc2_half,
            dc2_word,
            dc2_load,
            dc2_store,
            dc2_unsign,
            dc2_legal,
            dc2_unaligned_addr,
            dc1_computed_addr,
            dc1_rd_addr,
            dc2_lsu_valid,
            dc1_store_needs_load,
            dc1_rs2_data,
            dc1_store_forward,
            dc1_forward_value
          }
      ))
  ) dc2_dccm_rdata_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
        dc1_by,
        dc1_half,
        dc1_word,
        dc1_load,
        dc1_store,
        dc1_unsign,
        dc1_legal,
        dc1_unaligned_addr,
        dc1_computed_addr,
        dc1_rd_addr,
        dc1_lsu_valid,
        dc1_store_needs_load,
        dc1_rs2_data,
        dc1_store_forward,
        dc1_forward_value
      }),
      .dout({
        dc2_by,
        dc2_half,
        dc2_word,
        dc2_load,
        dc2_store,
        dc2_unsign,
        dc2_legal,
        dc2_unaligned_addr,
        dc2_computed_addr,
        dc2_rd_addr,
        dc2_lsu_valid,
        dc2_store_needs_load,
        dc2_rs2_data,
        dc2_store_forward,
        dc2_forward_value
      })
  );

  register_sync_rstn #(
      .WIDTH(XLEN)
  ) dc2_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc1_lsu_instr_tag_out),
      .dout(dc2_lsu_instr_tag_out)
  );

  register_sync_rstn #(
      .WIDTH(32)
  ) dc2_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc1_lsu_instr_out),
      .dout(dc2_lsu_instr_out)
  );

  logic [2*XLEN-1:0] dc2_store_mask_base;
  logic [2*XLEN-1:0] dc2_store_mask;

  logic [2*XLEN-1:0] dc2_store_buffer;

  assign dc2_store_mask_base = {2*XLEN{dc2_by}} & 64'h00000000000000FF | 
                               {2*XLEN{dc2_half}} & 64'h000000000000FFFF | 
                               {2*XLEN{dc2_word}} & 64'h00000000FFFFFFFF;

  assign dc2_store_mask = dc2_store_mask_base << {dc2_computed_addr[1:0], 3'b000};

  assign dc2_store_buffer = (dc2_store_forward) ? (({{XLEN{1'b0}},dc2_rs2_data} & dc2_store_mask_base) << {dc2_computed_addr[1:0], 3'b000}) | ({{XLEN{1'b0}}, dc2_forward_value} & ~dc2_store_mask) : 
                                                  (({{XLEN{1'b0}},dc2_rs2_data} & dc2_store_mask_base) << {dc2_computed_addr[1:0], 3'b000}) | ({{XLEN{1'b0}}, lsu_dccm_rdata} & ~dc2_store_mask);

  assign dc2_store_forward_next = ((dc2_store | dc2_load) & dc2_legal & dc2_unaligned_addr) & (dc3_store & dc3_legal) & (lsu_dccm_waddr[XLEN-1:0] == {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00});
  assign dc2_forward_value_next = lsu_dccm_wdata;

  assign dc2_load_buffer = (dc2_store_forward) ? dc2_forward_value >> {dc2_computed_addr[1:0], 3'b000} : lsu_dccm_rdata >> {dc2_computed_addr[1:0], 3'b000};

  /* ****** DC3 ***** */
  register_sync_rstn #(
      .WIDTH($bits(
          {
            dc3_load_buffer,
            dc3_unaligned_addr,
            dc3_computed_addr,
            dc3_by,
            dc3_half,
            dc3_word,
            dc3_load,
            dc3_store,
            dc3_unsign,
            dc3_legal,
            dc3_rd_addr,
            dc3_rs2_data,
            dc3_store_forward,
            dc3_forward_value
          }
      ))
  ) dc3_dccm_rdata_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
        dc2_load_buffer,
        dc2_unaligned_addr,
        dc2_computed_addr,
        dc2_by,
        dc2_half,
        dc2_word,
        dc2_load,
        dc2_store,
        dc2_unsign,
        dc2_legal,
        dc2_rd_addr,
        dc2_rs2_data,
        dc2_store_forward_next,
        dc2_forward_value_next
      }),
      .dout({
        dc3_load_buffer,
        dc3_unaligned_addr,
        dc3_computed_addr,
        dc3_by,
        dc3_half,
        dc3_word,
        dc3_load,
        dc3_store,
        dc3_unsign,
        dc3_legal,
        dc3_rd_addr,
        dc3_rs2_data,
        dc3_store_forward,
        dc3_forward_value
      })
  );

  register_sync_rstn #(
      .WIDTH(XLEN)
  ) dc3_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc2_lsu_instr_tag_out),
      .dout(dc3_lsu_instr_tag_out)
  );

  register_sync_rstn #(
      .WIDTH(32)
  ) dc3_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc2_lsu_instr_out),
      .dout(dc3_lsu_instr_out)
  );

  register_sync_rstn #(
      .WIDTH(1)
  ) stall_reg (
      .clk (clk),
      .rstn(rstn),
      .din (lsu_stall),
      .dout(lsu_stall_q)
  );

  assign dc3_shamt_by = (3'd4 - {1'd0, dc3_computed_addr[1:0]});
  assign dc3_shamt = {dc3_shamt_by[1:0], 3'b000};

  //assign dc3_wb_data = (dc3_unaligned_addr) ? (dc3_load_buffer | (lsu_dccm_rdata << dc3_shamt)) : dc3_load_buffer;

  assign dc3_wb_data = ({XLEN{~dc3_unaligned_addr & ~dc3_store_forward}} & dc3_load_buffer) | 
                        ({XLEN{dc3_unaligned_addr & ~dc3_store_forward}} & (dc3_load_buffer | (lsu_dccm_rdata << dc3_shamt))) | 
                       ({XLEN{~dc3_unaligned_addr & dc3_store_forward}} & dc3_forward_value) | 
                       ({XLEN{dc3_unaligned_addr & dc3_store_forward}} & (dc3_load_buffer | (dc3_forward_value << dc3_shamt)));

  assign dc3_wb_sext_mask = ({{XLEN-8{dc3_by & ~dc3_unsign & dc3_wb_data[7]}} & 24'hFFFFFF, 8'h00}) | 
                            ({{XLEN-16{dc3_half & ~dc3_unsign & dc3_wb_data[15]}} & 16'hFFFF, 16'h0000});

  assign dc3_wb_data_mask = ({XLEN{dc3_by}} & 32'h000000FF) | 
                            ({XLEN{dc3_half}} & 32'h0000FFFF) | 
                            ({XLEN{dc3_word}} & 32'hFFFFFFFF);

  assign dc3_store_buffer = (dc3_store_forward) ? (dc3_rs2_data >> dc3_shamt) | (dc3_forward_value & ~(dc3_wb_data_mask << dc3_shamt)) : 
                                                  (dc3_rs2_data >> dc3_shamt) | (lsu_dccm_rdata & ~(dc3_wb_data_mask << dc3_shamt));

  /* Mem Read Interface */
  assign lsu_dccm_raddr = ({XLEN{dc1_lsu_valid & (dc1_load | dc1_store_needs_load) & ~dc2_unaligned_addr}} & {dc1_computed_addr[XLEN-1:2], 2'b00}) |
                          ({XLEN{dc2_lsu_valid & (dc2_load | dc2_store_needs_load) & dc2_unaligned_addr}} & {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00});

  assign lsu_dccm_rvalid_in = (dc1_lsu_valid & ~dc2_unaligned_addr & ~dc1_store_forward) |
                              (dc2_lsu_valid & dc2_unaligned_addr & ~dc2_store_forward);

  /* Memory Write Interface */
  assign lsu_dccm_waddr = ({XLEN{dc2_legal & dc2_store & ~dc3_unaligned_addr}} & {dc2_computed_addr[XLEN-1:2], 2'b00}) |
                          ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} & {dc3_computed_addr[XLEN-1:2] + 30'd1, 2'b00});

  assign lsu_dccm_wen = (dc2_legal & dc2_store) | (dc3_legal & dc3_store & dc3_unaligned_addr);

  assign lsu_dccm_wdata = ({XLEN{dc2_legal & dc2_store & ~dc3_unaligned_addr}} & dc2_store_buffer[XLEN-1:0]) |
                          ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} & dc3_store_buffer);

  /* EXU Write Back */
  assign lsu_wb_rd_wr_en = dc3_load & dc3_legal;
  assign lsu_wb_rd_addr = dc3_rd_addr;
  assign lsu_wb_data = (dc3_wb_data & dc3_wb_data_mask) | dc3_wb_sext_mask;

  /* Stall and Busy Signals */
  assign lsu_stall = dc1_unaligned_addr;
  assign lsu_busy = dc1_lsu_valid | dc2_lsu_valid;

  assign instr_tag_out = dc3_lsu_instr_tag_out;
  assign instr_out = dc3_lsu_instr_out;

endmodule
