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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Core Top Test Bench
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

module core_top_tb;

  localparam string ICCM_INIT_FILE = `ICCM_INIT_FILE;
  localparam string DCCM_INIT_FILE = `DCCM_INIT_FILE;
  localparam logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = `STACK_POINTER_INIT_VALUE;
  localparam int TB_LANE = 0;

  logic            clk = 0;
  logic            rstn;
  logic [XLEN-1:0] reset_vector = `RESET_VECTOR;

  logic [    31:0] cycle_count = 0;

  int              fd;
  int              fd_console;

  logic            reset_last_retired = 0;
  core_debug_lane_t dbg;

  core_debug_lane_t core_debug[ISSUE_WIDTH-1:0];
  logic [XLEN-1:0]  core_dccm_waddr;
  logic             core_dccm_wen;
  logic [XLEN-1:0]  core_dccm_wdata;

  /* DUT Instantiation */
  soc_top #(
      .ICCM_INIT_FILE          (ICCM_INIT_FILE),
      .DCCM_INIT_FILE          (DCCM_INIT_FILE),
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) soc_top_i (
      .*
  );

  assign dbg = core_debug[TB_LANE];

  always #5 clk = ~clk;  // 100 MHz clock

  initial begin
    $timeformat(-9, 3, " ns", 10);
    fd = $fopen("rtl.log", "w");
    fd_console = $fopen("console.log", "w");
    rstn = 0;
    for (int i = 0; i < 10; i++) begin
      @(negedge clk);
    end
    rstn = 1;
  end

  logic finish_seq_detected;
  always_ff @(posedge clk) begin
    if (core_dccm_wen & core_dccm_waddr == 32'h10000000) begin
      finish_seq_detected <= 1;
    end
  end

  always_ff @(posedge clk) begin
    if (core_dccm_wen & core_dccm_waddr == 32'h00200000) begin
      $fwrite(fd_console, "%c", core_dccm_wdata[7:0]);
    end
  end

  logic [31:0] cycle_count_last_retired = 0;
  always_ff @(posedge clk) begin
    if (finish_seq_detected) begin
      $finish;
    end
    if (cycle_count_last_retired > 10000) begin
      $fdisplay(fd, "[%d] Nothing retired in 10000 cycles... Aborting", cycle_count);
      $finish;
    end
  end

  always_ff @(posedge clk) begin
    if (rstn) begin
      cycle_count <= cycle_count + 1;
    end
    if (reset_last_retired) cycle_count_last_retired <= 32'b0;
    else cycle_count_last_retired <= cycle_count_last_retired + 1;
  end

  always_ff @(posedge clk) begin
    reset_last_retired <= 1'b0;

    if (dbg.reg_wr) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;x%0D=0x%H", cycle_count, dbg.wb_instr_tag, dbg.wb_instr,
                dbg.wb_rd_addr, dbg.wb_data);
      reset_last_retired <= 1'b1;
    end

    if (dbg.reg_wr_jal) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;x%0D=0x%H;pc=0x%H", cycle_count, dbg.wb_instr_tag, dbg.wb_instr,
                dbg.wb_rd_addr, dbg.wb_data, dbg.wb_pc);
      reset_last_retired <= 1'b1;
    end

    if (dbg.br_taken) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;taken=true;pc=0x%H", cycle_count, dbg.br_taken_instr_tag,
                dbg.br_taken_instr, dbg.br_taken_pc);
      reset_last_retired <= 1'b1;
    end

    if (dbg.br_not_taken) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;taken=false", cycle_count + 1, dbg.br_not_taken_instr_tag,
                dbg.br_not_taken_instr);
      reset_last_retired <= 1'b1;
    end

    if (dbg.mem_store) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;mem[0x%8H]=0x%H", cycle_count, dbg.mem_store_instr_tag,
                dbg.mem_store_instr, dbg.mem_store_addr, dbg.mem_store_wdata);
      reset_last_retired <= 1'b1;
    end

    if (dbg.mem_store_unaligned) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;mem[0x%8H]=0x%H", cycle_count,
                dbg.mem_store_unaligned_instr_tag, dbg.mem_store_unaligned_instr,
                dbg.mem_store_unaligned_addr, dbg.mem_store_unaligned_wdata);
      reset_last_retired <= 1'b1;
    end

    if (dbg.ecall) begin
      $fdisplay(fd, "%5d;0x%H;0x%H;ecall", cycle_count, dbg.ecall_instr_tag, dbg.ecall_instr);
      reset_last_retired <= 1'b1;
    end
  end

endmodule
