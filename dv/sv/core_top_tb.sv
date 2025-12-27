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

module core_top_tb;

  localparam string ICCM_INIT_FILE = `ICCM_INIT_FILE;
  localparam string DCCM_INIT_FILE = `DCCM_INIT_FILE;
  localparam logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = `STACK_POINTER_INIT_VALUE;

  logic            clk = 0;
  logic            rstn;
  logic [XLEN-1:0] reset_vector = `RESET_VECTOR;

  logic [    31:0] cycle_count = 0;

  int              fd;
  int              fd_console;

  logic            reset_last_retired = 0;
  /* DUT Instantiation */
  core_top #(
      .ICCM_INIT_FILE          (ICCM_INIT_FILE),
      .DCCM_INIT_FILE          (DCCM_INIT_FILE),
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) core_top_i (
      .*
  );

  always #5 clk = ~clk;  // 100 MHz clock

  initial begin
    /* Create a log file in the current directory */
    $timeformat(-9, 3, " ns", 10);
    fd = $fopen("rtl.log", "w");
    fd_console = $fopen("console.log", "w");
    rstn = 0;
    for (int i = 0; i < 10; i++) begin
      @(negedge clk);
    end
    rstn = 1;
  end

  /* Finish Sequence Detector */
  logic finish_seq_detected;
  always_ff @(posedge clk) begin
    if (core_top_i.dccm_wen & core_top_i.dccm_waddr == 32'h10000000) begin
      finish_seq_detected <= 1;
    end
  end

  /* Console output */
  always_ff @(posedge clk) begin
    if (core_top_i.dccm_wen & core_top_i.dccm_waddr == 32'h00200000) begin
      $fwrite(fd_console, "%c", core_top_i.dccm_wdata[7:0]);
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

  /* Cycle counter */
  always_ff @(posedge clk) begin
    if (rstn) begin
      cycle_count <= cycle_count + 1;
    end
    if (reset_last_retired) cycle_count_last_retired <= 32'b0;
    else cycle_count_last_retired <= cycle_count_last_retired + 1;
  end

  /* Use the monitor to log the log file */
  always_ff @(posedge clk) begin
    reset_last_retired <= 'b0;
    /* Log everytime we touch the state of our core: Write to the register file, change the PC and store to memory */
    if (core_top_i.exu_wb_rd_wr_en & ~core_top_i.ifu_inst.pc_load) begin  /* Hierarchical naming */
      $fdisplay(fd, "%5d;0x%H;0x%H;x%0D=0x%H", cycle_count, core_top_i.exu_instr_tag_out,
                core_top_i.exu_instr_out, core_top_i.exu_wb_rd_addr, core_top_i.exu_wb_data);
      reset_last_retired <= 1'b1;
    end
    if (core_top_i.exu_wb_rd_wr_en & core_top_i.ifu_inst.pc_load) begin  /* JAL/JALR */
      $fdisplay(fd, "%5d;0x%H;0x%H;x%0D=0x%H;pc=0x%H", cycle_count, core_top_i.exu_instr_tag_out,
                core_top_i.exu_instr_out, core_top_i.exu_wb_rd_addr, core_top_i.exu_wb_data,
                core_top_i.ifu_inst.pc_exu);
      reset_last_retired <= 1'b1;
    end

    if (~core_top_i.exu_inst.alu_wb_rd_wr_en & core_top_i.ifu_inst.pc_load) begin  /* BEQ/BNE/BGE/BLT/BLTU/BGEU taken */
      $fdisplay(fd, "%5d;0x%H;0x%H;taken=true;pc=0x%H", cycle_count,
                core_top_i.exu_inst.alu_instr_tag_out, core_top_i.exu_inst.alu_instr_out,
                core_top_i.ifu_inst.pc_exu);
      reset_last_retired <= 1'b1;
    end

    if (core_top_i.exu_inst.alu_inst.alu_ctrl.condbr & ~core_top_i.exu_inst.alu_inst.brn_taken & core_top_i.exu_inst.alu_inst.alu_ctrl.legal) begin  /* BEQ/BNE/BGE/BLT/BLTU/BGEU not taken */
      $fdisplay(fd, "%5d;0x%H;0x%H;taken=false", cycle_count + 1,
                core_top_i.exu_inst.alu_inst.alu_ctrl.instr_tag,
                core_top_i.exu_inst.alu_inst.alu_ctrl.instr);
      reset_last_retired <= 1'b1;
    end

    if (core_top_i.exu_inst.lsu_inst.dc2_legal & core_top_i.exu_inst.lsu_inst.dc2_store) begin
      $fdisplay(
          fd, "%5d;0x%H;0x%H;mem[0x%8H]=0x%H", cycle_count,
          core_top_i.exu_inst.lsu_inst.dc2_lsu_instr_tag_out,
          core_top_i.exu_inst.lsu_inst.dc2_lsu_instr_out,
          core_top_i.exu_inst.lsu_inst.dc2_computed_addr,
          (core_top_i.exu_inst.lsu_inst.dc2_store_buffer[XLEN-1:0] >> {core_top_i.exu_inst.lsu_inst.dc2_computed_addr[1:0], 3'b000}) & core_top_i.exu_inst.lsu_inst.dc2_store_mask_base[XLEN-1:0]);
      reset_last_retired <= 1'b1;
    end

    if (core_top_i.exu_inst.lsu_inst.dc3_legal & core_top_i.exu_inst.lsu_inst.dc3_store & core_top_i.exu_inst.lsu_inst.dc3_unaligned_addr) begin
      $fdisplay(
          fd, "%5d;0x%H;0x%H;mem[0x%8H]=0x%H", cycle_count,
          core_top_i.exu_inst.lsu_inst.dc3_lsu_instr_tag_out,
          core_top_i.exu_inst.lsu_inst.dc3_lsu_instr_out,
          core_top_i.exu_inst.lsu_inst.dc3_computed_addr,
          core_top_i.exu_inst.lsu_inst.dc3_store_buffer[XLEN-1:0] & core_top_i.exu_inst.lsu_inst.dc3_wb_data_mask[XLEN-1:0]);
      reset_last_retired <= 1'b1;
    end

    if (core_top_i.exu_inst.ecall_exe) begin  /* Hierarchical naming */
      $fdisplay(fd, "%5d;0x%H;0x%H;ecall", cycle_count, core_top_i.exu_instr_tag_out,
                core_top_i.exu_instr_out);
      reset_last_retired <= 1'b1;
    end
  end


endmodule
