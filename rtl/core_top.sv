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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Core Top
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

/* ***** Tiny Vedas Core Top (pipeline only; memories live in soc_top) ***** */

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

module core_top #(
    parameter logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h80000000
) (

    /* Clock and Reset */
    input logic            clk,
    input logic            rstn,
    input logic [XLEN-1:0] reset_vector,

    /* Instruction Memory <-> IFU Interface */
    output logic [       INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr,
    output logic                                   instr_mem_addr_valid,
    output logic [        INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_out,
    input  logic [INSTR_MEM_WIDTH*ISSUE_WIDTH-1:0] instr_mem_rdata,
    input  logic                                   instr_mem_rdata_valid,
    input  logic [        INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in,

    /* Data Memory <-> EXU/LSU Interface */
    output logic [XLEN-1:0] dccm_raddr,
    output logic            dccm_rvalid_in,
    input  logic [XLEN-1:0] dccm_rdata,
    input  logic            dccm_rvalid_out,
    output logic [XLEN-1:0] dccm_waddr,
    output logic            dccm_wen,
    output logic [XLEN-1:0] dccm_wdata
`ifndef SYNTHESIS
    ,
    output core_debug_lane_t debug[ISSUE_WIDTH-1:0]
`endif

);

  /* IFU -> IDU0 Interface */
  logic [ISSUE_WIDTH-1:0][INSTR_LEN-1:0] instr;
  logic [ISSUE_WIDTH-1:0] instr_valid;

  /* IDU0 -> IDU1 Interface */
  idu0_out_t idu0_out;

  /* IDU1 -> EXU Interface */
  idu1_out_t idu1_out;
  logic pipe_stall;
  logic idu0_rsb_hit_stall;

  /* IDU1 -> Register File Interface */
  logic [REG_FILE_ADDR_WIDTH-1:0] rs1_addr[ISSUE_WIDTH-1:0];
  logic [REG_FILE_ADDR_WIDTH-1:0] rs2_addr[ISSUE_WIDTH-1:0];
  logic rs1_rd_en[ISSUE_WIDTH-1:0];
  logic rs2_rd_en[ISSUE_WIDTH-1:0];
  logic [XLEN-1:0] rs1_data[ISSUE_WIDTH-1:0];
  logic [XLEN-1:0] rs2_data[ISSUE_WIDTH-1:0];

  /* IDU1 <-> Register Scoreboard Interface */
  logic [ISSUE_WIDTH-1:0][REG_FILE_ADDR_WIDTH-1:0] rsb_set_rd_addr;
  logic [ISSUE_WIDTH-1:0] rsb_set_rd_wr_en;
  logic rs1_rsb_hit[ISSUE_WIDTH-1:0];
  logic rs2_rsb_hit[ISSUE_WIDTH-1:0];

  /* EXU -> IDU1 (WB) Interface */
  logic [ISSUE_WIDTH-1:0][XLEN-1:0] exu_wb_data;
  logic [ISSUE_WIDTH-1:0][REG_FILE_ADDR_WIDTH-1:0] exu_wb_rd_addr;
  logic [ISSUE_WIDTH-1:0] exu_wb_rd_wr_en;
  logic [ISSUE_WIDTH-1:0] exu_mul_busy;
  logic [ISSUE_WIDTH-1:0] exu_div_busy;
  logic [ISSUE_WIDTH-1:0] exu_lsu_busy;
  logic [ISSUE_WIDTH-1:0] exu_lsu_stall;

  /* EXU -> PC Interface */
  logic [ISSUE_WIDTH-1:0][XLEN-1:0] pc_out;
  logic [ISSUE_WIDTH-1:0] pc_load;

`ifndef SYNTHESIS
  logic [ISSUE_WIDTH-1:0][XLEN-1:0] exu_instr_tag_out;
  logic [ISSUE_WIDTH-1:0][XLEN-1:0] exu_instr_out;
`endif
  logic [ISSUE_WIDTH-1:0][XLEN-1:0] instr_tag;

  ifu ifu_inst (
      .clk                  (clk),
      .rstn                 (rstn),
      .reset_vector         (reset_vector),
      .instr_mem_addr       (instr_mem_addr),
      .instr_mem_addr_valid (instr_mem_addr_valid),
      .instr_mem_rdata      (instr_mem_rdata),
      .instr_mem_rdata_valid(instr_mem_rdata_valid),
      .instr_mem_tag_out    (instr_mem_tag_out),
      .instr_mem_tag_in     (instr_mem_tag_in),
      .instr                (instr),
      .instr_valid          (instr_valid),
      .instr_tag            (instr_tag),
      .pipe_stall           (pipe_stall | idu0_rsb_hit_stall),
      .pc_exu               (pc_out),
      .pc_load              (pc_load)
  );

  /* Register File */
  reg_file #(
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE),
      .N_RPORTS_PAIRS          (ISSUE_WIDTH),
      .N_WPORTS                (ISSUE_WIDTH)
  ) reg_file_inst (
      .clk      (clk),
      .rstn     (rstn),
      .rs1_addr (rs1_addr),
      .rs2_addr (rs2_addr),
      .rs1_rd_en(rs1_rd_en),
      .rs2_rd_en(rs2_rd_en),
      .rs1_data (rs1_data),
      .rs2_data (rs2_data),
      .rd_addr  (exu_wb_rd_addr),
      .rd_data  (exu_wb_data),
      .rd_wr_en (exu_wb_rd_wr_en)
  );

  /* Register Scoreboard */
  rsb #(
      .N_REG          (REG_FILE_DEPTH),
      .N_RPORTS_PAIRS (ISSUE_WIDTH),
      .N_WPORTS       (ISSUE_WIDTH)
  ) rsb_inst (
      .clk           (clk),
      .rstn          (rstn),
      .pipe_flush    (pc_load[0]),
      .rs1_addr      (rs1_addr),
      .rs2_addr      (rs2_addr),
      .rs1_rd_en     (rs1_rd_en),
      .rs2_rd_en     (rs2_rd_en),
      .rs1_hit       (rs1_rsb_hit),
      .rs2_hit       (rs2_rsb_hit),
      .set_rd_addr   (rsb_set_rd_addr),
      .set_rd_wr_en  (rsb_set_rd_wr_en),
      .clear_rd_addr (exu_wb_rd_addr),
      .clear_rd_wr_en(exu_wb_rd_wr_en)
  );

  idu0 idu0_inst (
      .clk        (clk),
      .rstn       (rstn),
      .instr      (instr[0]),
      .instr_valid(instr_valid[0]),
      .instr_tag  (instr_tag[0]),
      .pipe_stall (pipe_stall | idu0_rsb_hit_stall),
      .idu0_out   (idu0_out),
      .pipe_flush (pc_load[0])
  );

  idu1 #(
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) idu1_inst (
      .clk               (clk),
      .rstn              (rstn),
      .idu0_out          (idu0_out),
      .idu1_out          (idu1_out),
      .rs1_addr          (rs1_addr[0]),
      .rs2_addr          (rs2_addr[0]),
      .rs1_rd_en         (rs1_rd_en[0]),
      .rs2_rd_en         (rs2_rd_en[0]),
      .rs1_data          (rs1_data[0]),
      .rs2_data          (rs2_data[0]),
      .rsb_set_rd_addr   (rsb_set_rd_addr[0]),
      .rsb_set_rd_wr_en  (rsb_set_rd_wr_en[0]),
      .rs1_rsb_hit       (rs1_rsb_hit[0]),
      .rs2_rsb_hit       (rs2_rsb_hit[0]),
      .exu_wb_data       (exu_wb_data[0]),
      .exu_wb_rd_addr    (exu_wb_rd_addr[0]),
      .exu_wb_rd_wr_en   (exu_wb_rd_wr_en[0]),
      .exu_mul_busy      (exu_mul_busy[0]),
      .exu_div_busy      (exu_div_busy[0]),
      .exu_lsu_busy      (exu_lsu_busy[0]),
      .exu_lsu_stall     (exu_lsu_stall[0]),
      .pipe_stall        (pipe_stall),
      .idu0_rsb_hit_stall(idu0_rsb_hit_stall),
      .pipe_flush        (pc_load)
  );

  exu #(
      .HAS_ALU(EXU_HAS_ALU[0]),
      .HAS_MUL(EXU_HAS_MUL[0]),
      .HAS_DIV(EXU_HAS_DIV[0]),
      .HAS_LSU(EXU_HAS_LSU[0])
  ) exu_inst (
      .clk            (clk),
      .rstn           (rstn),
      .idu1_out       (idu1_out),
      .exu_wb_data    (exu_wb_data[0]),
      .exu_wb_rd_addr (exu_wb_rd_addr[0]),
      .exu_wb_rd_wr_en(exu_wb_rd_wr_en[0]),
      .exu_mul_busy   (exu_mul_busy[0]),
      .exu_div_busy   (exu_div_busy[0]),
      .exu_lsu_busy   (exu_lsu_busy[0]),
      .exu_lsu_stall  (exu_lsu_stall[0]),
      .dccm_raddr     (dccm_raddr),
      .dccm_rvalid_in (dccm_rvalid_in),
      .dccm_rdata     (dccm_rdata),
      .dccm_rvalid_out(dccm_rvalid_out),
      .dccm_waddr     (dccm_waddr),
      .dccm_wen       (dccm_wen),
      .dccm_wdata     (dccm_wdata),
      .pc_out         (pc_out[0]),
      .pc_load        (pc_load[0])
`ifndef SYNTHESIS
      ,
      .instr_tag_out(exu_instr_tag_out[0]),
      .instr_out    (exu_instr_out[0]),
      .debug        (debug[0])
`endif
  );

`ifndef SYNTHESIS
  generate
    for (genvar lane = 1; lane < ISSUE_WIDTH; lane++) begin : g_unused_debug
      assign debug[lane] = '0;
    end
  endgenerate
`endif

endmodule
