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
    input  logic            clk,
    input  logic            rstn,
    input  logic [XLEN-1:0] reset_vector,

    /* Instruction Memory <-> IFU Interface */
    output logic      [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr,
    output logic                                 instr_mem_addr_valid,
    output logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_out,
    input  logic      [     INSTR_MEM_WIDTH-1:0] instr_mem_rdata,
    input  logic                                 instr_mem_rdata_valid,
    input  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in,

    /* Data Memory <-> EXU/LSU Interface */
    output logic      [                XLEN-1:0] dccm_raddr,
    output logic                                 dccm_rvalid_in,
    input  logic      [                XLEN-1:0] dccm_rdata,
    input  logic                                 dccm_rvalid_out,
    output logic      [                XLEN-1:0] dccm_waddr,
    output logic                                 dccm_wen,
    output logic      [                XLEN-1:0] dccm_wdata

);

  /* IFU -> IDU0 Interface */
  logic      [           INSTR_LEN-1:0] instr;
  logic                                 instr_valid;

  /* IDU0 -> IDU1 Interface */
  idu0_out_t                            idu0_out;

  /* IDU1 -> EXU Interface */
  idu1_out_t                            idu1_out;
  logic                                 pipe_stall;
  logic                                 idu0_rsb_hit_stall;

  /* EXU -> IDU1 (WB) Interface */
  logic      [                XLEN-1:0] exu_wb_data;
  logic      [ REG_FILE_ADDR_WIDTH-1:0] exu_wb_rd_addr;
  logic                                 exu_wb_rd_wr_en;
  logic                                 exu_mul_busy;
  logic                                 exu_div_busy;
  logic                                 exu_lsu_busy;
  logic                                 exu_lsu_stall;

  /* EXU -> PC Interface */
  logic      [                XLEN-1:0] pc_out;
  logic                                 pc_load;

  /* ONLY FOR DEBUG */
  logic      [                XLEN-1:0] exu_instr_tag_out;
  logic      [                XLEN-1:0] exu_instr_out;
  logic      [                XLEN-1:0] instr_tag;

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

  idu0 idu0_inst (
      .clk        (clk),
      .rstn       (rstn),
      .instr      (instr),
      .instr_valid(instr_valid),
      .instr_tag  (instr_tag),
      .pipe_stall (pipe_stall | idu0_rsb_hit_stall),
      .idu0_out   (idu0_out),
      .pipe_flush (pc_load)
  );

  idu1 #(
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) idu1_inst (
      .clk               (clk),
      .rstn              (rstn),
      .idu0_out          (idu0_out),
      .idu1_out          (idu1_out),
      .exu_wb_data       (exu_wb_data),
      .exu_wb_rd_addr    (exu_wb_rd_addr),
      .exu_wb_rd_wr_en   (exu_wb_rd_wr_en),
      .exu_mul_busy      (exu_mul_busy),
      .exu_div_busy      (exu_div_busy),
      .exu_lsu_busy      (exu_lsu_busy),
      .exu_lsu_stall     (exu_lsu_stall),
      .pipe_stall        (pipe_stall),
      .idu0_rsb_hit_stall(idu0_rsb_hit_stall),
      .pipe_flush        (pc_load)
  );

  exu exu_inst (
      .clk            (clk),
      .rstn           (rstn),
      .idu1_out       (idu1_out),
      .instr_tag_out  (exu_instr_tag_out),
      .instr_out      (exu_instr_out),
      .exu_wb_data    (exu_wb_data),
      .exu_wb_rd_addr (exu_wb_rd_addr),
      .exu_wb_rd_wr_en(exu_wb_rd_wr_en),
      .exu_mul_busy   (exu_mul_busy),
      .exu_div_busy   (exu_div_busy),
      .exu_lsu_busy   (exu_lsu_busy),
      .exu_lsu_stall  (exu_lsu_stall),
      .dccm_raddr     (dccm_raddr),
      .dccm_rvalid_in (dccm_rvalid_in),
      .dccm_rdata     (dccm_rdata),
      .dccm_rvalid_out(dccm_rvalid_out),
      .dccm_waddr     (dccm_waddr),
      .dccm_wen       (dccm_wen),
      .dccm_wdata     (dccm_wdata),
      .pc_out         (pc_out),
      .pc_load        (pc_load)
  );

endmodule
