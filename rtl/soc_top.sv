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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - SoC Top
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

/* ***** Tiny Vedas SoC Top (core + on-chip memories) ***** */

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module soc_top #(
    parameter string ICCM_INIT_FILE = "",
    parameter string DCCM_INIT_FILE = "",
    parameter logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h80000000
) (

    input logic            clk,
    input logic            rstn,
    input logic [XLEN-1:0] reset_vector

);

  logic      [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr;
  logic                                 instr_mem_addr_valid;
  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_out;
  logic      [     INSTR_MEM_WIDTH-1:0] instr_mem_rdata;
  logic                                 instr_mem_rdata_valid;
  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in;

  logic      [                XLEN-1:0] dccm_raddr;
  logic                                 dccm_rvalid_in;
  logic      [                XLEN-1:0] dccm_rdata;
  logic                                 dccm_rvalid_out;
  logic      [                XLEN-1:0] dccm_waddr;
  logic                                 dccm_wen;
  logic      [                XLEN-1:0] dccm_wdata;

  core_top #(
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) core_i (
      .clk                  (clk),
      .rstn                 (rstn),
      .reset_vector         (reset_vector),
      .instr_mem_addr       (instr_mem_addr),
      .instr_mem_addr_valid (instr_mem_addr_valid),
      .instr_mem_tag_out    (instr_mem_tag_out),
      .instr_mem_rdata      (instr_mem_rdata),
      .instr_mem_rdata_valid(instr_mem_rdata_valid),
      .instr_mem_tag_in     (instr_mem_tag_in),
      .dccm_raddr           (dccm_raddr),
      .dccm_rvalid_in       (dccm_rvalid_in),
      .dccm_rdata           (dccm_rdata),
      .dccm_rvalid_out      (dccm_rvalid_out),
      .dccm_waddr           (dccm_waddr),
      .dccm_wen             (dccm_wen),
      .dccm_wdata           (dccm_wdata)
  );

  iccm #(
      .DEPTH(INSTR_MEM_DEPTH),
      .WIDTH(INSTR_MEM_WIDTH),
      .INIT_FILE(ICCM_INIT_FILE)
  ) iccm_inst (
      .clk       (clk),
      .rstn      (rstn),
      .raddr     (instr_mem_addr),
      .rtag_in   (instr_mem_tag_out),
      .rvalid_in (instr_mem_addr_valid),
      .rdata     (instr_mem_rdata),
      .rtag_out  (instr_mem_tag_in),
      .rvalid_out(instr_mem_rdata_valid)
  );

  dccm #(
      .DEPTH    (DATA_MEM_DEPTH),
      .WIDTH    (DATA_MEM_WIDTH),
      .INIT_FILE(DCCM_INIT_FILE)
  ) dccm_inst (
      .clk       (clk),
      .rstn      (rstn),
      .raddr     ({2'b00, dccm_raddr[DATA_MEM_ADDR_WIDTH-3:2]}),
      .rvalid_in (dccm_rvalid_in),
      .rdata     (dccm_rdata),
      .rvalid_out(dccm_rvalid_out),
      .waddr     ({2'b00, dccm_waddr[DATA_MEM_ADDR_WIDTH-3:2]}),
      .wen       (dccm_wen),
      .wdata     (dccm_wdata)
  );

endmodule
