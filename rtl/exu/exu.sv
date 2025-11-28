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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - EXU
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

module exu (
    input logic clk,
    input logic rstn,

    /* IDU1 -> EXU Interface */
    input idu1_out_t idu1_out,

    /* ONLY FOR DEBUG */
    output logic [     XLEN-1:0] instr_tag_out,
    output logic [INSTR_LEN-1:0] instr_out,

    /* EXU -> IDU1 (WB) Interface */
    output logic [               XLEN-1:0] exu_wb_data,
    output logic [REG_FILE_ADDR_WIDTH-1:0] exu_wb_rd_addr,
    output logic                           exu_wb_rd_wr_en,
    output logic                           exu_mul_busy,
    output logic                           exu_div_busy,
    output logic                           exu_lsu_busy,
    output logic                           exu_lsu_stall,

    /* DCCM Interface */
    output logic [XLEN-1:0] dccm_raddr,
    output logic            dccm_rvalid_in,
    input  logic [XLEN-1:0] dccm_rdata,
    input  logic            dccm_rvalid_out,
    output logic [XLEN-1:0] dccm_waddr,
    output logic            dccm_wen,
    output logic [XLEN-1:0] dccm_wdata,

    /* PC Interface */
    output logic [XLEN-1:0] pc_out,
    output logic            pc_load
);

  logic [               XLEN-1:0] alu_wb_data;
  logic [REG_FILE_ADDR_WIDTH-1:0] alu_wb_rd_addr;
  logic                           alu_wb_rd_wr_en;

  logic [               XLEN-1:0] mul_wb_data;
  logic [REG_FILE_ADDR_WIDTH-1:0] mul_wb_rd_addr;
  logic                           mul_wb_rd_wr_en;

  logic [               XLEN-1:0] div_wb_data;
  logic [REG_FILE_ADDR_WIDTH-1:0] div_wb_rd_addr;
  logic                           div_wb_rd_wr_en;

  logic [               XLEN-1:0] lsu_wb_data;
  logic [REG_FILE_ADDR_WIDTH-1:0] lsu_wb_rd_addr;
  logic                           lsu_wb_rd_wr_en;

  /* ONLY FOR DEBUG */
  logic [               XLEN-1:0] alu_instr_tag_out;
  logic [          INSTR_LEN-1:0] alu_instr_out;
  logic [               XLEN-1:0] mul_instr_tag_out;
  logic [          INSTR_LEN-1:0] mul_instr_out;
  logic [               XLEN-1:0] div_instr_tag_out;
  logic [          INSTR_LEN-1:0] div_instr_out;
  logic [               XLEN-1:0] lsu_instr_tag_out;
  logic [          INSTR_LEN-1:0] lsu_instr_out;

  alu alu_inst (
      .clk            (clk),
      .rstn           (rstn),
      .alu_ctrl       (idu1_out),
      .alu_wb_data    (alu_wb_data),
      .alu_wb_rd_addr (alu_wb_rd_addr),
      .alu_wb_rd_wr_en(alu_wb_rd_wr_en),
      .instr_tag_out  (alu_instr_tag_out),
      .instr_out      (alu_instr_out),
      .pc_out         (pc_out),
      .pc_load        (pc_load)
  );

  mul mul_inst (
      .clk          (clk),
      .rstn         (rstn),
      .freeze       (1'b0),
      .mul_ctrl     (idu1_out),
      .out          (mul_wb_data),
      .out_rd_addr  (mul_wb_rd_addr),
      .out_rd_wr_en (mul_wb_rd_wr_en),
      .instr_tag_out(mul_instr_tag_out),
      .instr_out    (mul_instr_out),
      .mul_busy     (exu_mul_busy)
  );

  div div_inst (
      .clk                     (clk),
      .rstn                    (rstn),
      .dp                      (idu1_out),
      .dec_tlu_fast_div_disable(1'b0),
      .flush_lower             (1'b0),
      .out                     (div_wb_data),
      .out_addr                (div_wb_rd_addr),
      .out_valid               (div_wb_rd_wr_en),
      .finish                  (),
      .finish_early            (),
      .valid_ff_e1             (),
      .instr_out               (div_instr_out),
      .instr_tag_out           (div_instr_tag_out),
      .div_stall               (exu_div_busy)
  );

  lsu lsu_inst (
      .clk                (clk),
      .rstn               (rstn),
      .lsu_ctrl           (idu1_out),
      .lsu_wb_data        (lsu_wb_data),
      .lsu_wb_rd_addr     (lsu_wb_rd_addr),
      .lsu_wb_rd_wr_en    (lsu_wb_rd_wr_en),
      .instr_tag_out      (lsu_instr_tag_out),
      .instr_out          (lsu_instr_out),
      .lsu_busy           (exu_lsu_busy),
      .lsu_stall          (exu_lsu_stall),
      .lsu_dccm_raddr     (dccm_raddr),
      .lsu_dccm_rvalid_in (dccm_rvalid_in),
      .lsu_dccm_rdata     (dccm_rdata),
      .lsu_dccm_rvalid_out(dccm_rvalid_out),
      .lsu_dccm_waddr     (dccm_waddr),
      .lsu_dccm_wen       (dccm_wen),
      .lsu_dccm_wdata     (dccm_wdata)
  );

  assign exu_wb_data = ({XLEN{alu_wb_rd_wr_en}} & alu_wb_data) | 
                       ({XLEN{mul_wb_rd_wr_en}} & mul_wb_data) | 
                       ({XLEN{div_wb_rd_wr_en}} & div_wb_data) |
                       ({XLEN{lsu_wb_rd_wr_en}} & lsu_wb_data);

  assign exu_wb_rd_addr = ({REG_FILE_ADDR_WIDTH{alu_wb_rd_wr_en}} & alu_wb_rd_addr) | 
                          ({REG_FILE_ADDR_WIDTH{mul_wb_rd_wr_en}} & mul_wb_rd_addr) | 
                          ({REG_FILE_ADDR_WIDTH{div_wb_rd_wr_en}} & div_wb_rd_addr) |
                          ({REG_FILE_ADDR_WIDTH{lsu_wb_rd_wr_en}} & lsu_wb_rd_addr);

  assign exu_wb_rd_wr_en = alu_wb_rd_wr_en | mul_wb_rd_wr_en | div_wb_rd_wr_en | lsu_wb_rd_wr_en;

  /* ONLY FOR DEBUG */
  assign instr_tag_out = ({XLEN{alu_wb_rd_wr_en}} & alu_instr_tag_out) | 
                         ({XLEN{mul_wb_rd_wr_en}} & mul_instr_tag_out) | 
                         ({XLEN{div_wb_rd_wr_en}} & div_instr_tag_out) |
                         ({XLEN{lsu_wb_rd_wr_en}} & lsu_instr_tag_out);

  assign instr_out = ({INSTR_LEN{alu_wb_rd_wr_en}} & alu_instr_out) | 
                     ({INSTR_LEN{mul_wb_rd_wr_en}} & mul_instr_out) | 
                     ({INSTR_LEN{div_wb_rd_wr_en}} & div_instr_out) |
                     ({INSTR_LEN{lsu_wb_rd_wr_en}} & lsu_instr_out);

endmodule
