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

module exu #(
    parameter int HAS_ALU = 1,
    parameter int HAS_MUL = 1,
    parameter int HAS_DIV = 1,
    parameter int HAS_LSU = 1
) (
    input logic clk,
    input logic rstn,

    /* IDU1 -> EXU Interface */
    input idu1_out_t idu1_out,

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
`ifndef SYNTHESIS
    ,
    output logic [     XLEN-1:0] instr_tag_out,
    output logic [INSTR_LEN-1:0] instr_out,
    output core_debug_lane_t     debug
`endif
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

`ifndef SYNTHESIS
  logic                           ecall_exe;
  logic [               XLEN-1:0] alu_instr_tag_out;
  logic [          INSTR_LEN-1:0] alu_instr_out;
  logic [               XLEN-1:0] mul_instr_tag_out;
  logic [          INSTR_LEN-1:0] mul_instr_out;
  logic [               XLEN-1:0] div_instr_tag_out;
  logic [          INSTR_LEN-1:0] div_instr_out;
  logic [               XLEN-1:0] lsu_instr_tag_out;
  logic [          INSTR_LEN-1:0] lsu_instr_out;
  logic [               XLEN-1:0] ecall_instr_tag_out;
  logic [          INSTR_LEN-1:0] ecall_instr_out;
  logic                           alu_debug_br_not_taken;
  logic [               XLEN-1:0] alu_debug_br_not_taken_instr_tag;
  logic [          INSTR_LEN-1:0] alu_debug_br_not_taken_instr;
  logic                           lsu_debug_store_dc2_valid;
  logic [               XLEN-1:0] lsu_debug_store_dc2_instr_tag;
  logic [          INSTR_LEN-1:0] lsu_debug_store_dc2_instr;
  logic [               XLEN-1:0] lsu_debug_store_dc2_addr;
  logic [               XLEN-1:0] lsu_debug_store_dc2_wdata;
  logic                           lsu_debug_store_dc3_valid;
  logic [               XLEN-1:0] lsu_debug_store_dc3_instr_tag;
  logic [          INSTR_LEN-1:0] lsu_debug_store_dc3_instr;
  logic [               XLEN-1:0] lsu_debug_store_dc3_addr;
  logic [               XLEN-1:0] lsu_debug_store_dc3_wdata;
`endif

  generate
    if (HAS_ALU != 0) begin
      alu alu_inst (
          .clk            (clk),
          .rstn           (rstn),
          .alu_ctrl       (idu1_out),
          .alu_wb_data    (alu_wb_data),
          .alu_wb_rd_addr (alu_wb_rd_addr),
          .alu_wb_rd_wr_en(alu_wb_rd_wr_en),
          .pc_out         (pc_out),
          .pc_load        (pc_load)
`ifndef SYNTHESIS
          ,
          .instr_tag_out               (alu_instr_tag_out),
          .instr_out                   (alu_instr_out),
          .debug_br_not_taken          (alu_debug_br_not_taken),
          .debug_br_not_taken_instr_tag(alu_debug_br_not_taken_instr_tag),
          .debug_br_not_taken_instr    (alu_debug_br_not_taken_instr)
`endif
      );
    end else begin
      assign alu_wb_data     = '0;
      assign alu_wb_rd_addr  = '0;
      assign alu_wb_rd_wr_en = 1'b0;
      assign pc_out          = '0;
      assign pc_load         = 1'b0;
`ifndef SYNTHESIS
      assign alu_instr_tag_out                = '0;
      assign alu_instr_out                    = '0;
      assign alu_debug_br_not_taken           = 1'b0;
      assign alu_debug_br_not_taken_instr_tag = '0;
      assign alu_debug_br_not_taken_instr     = '0;
`endif
    end

    if (HAS_MUL != 0) begin
      exu_mul exu_mul_inst (
          .clk          (clk),
          .rstn         (rstn),
          .freeze       (1'b0),
          .mul_ctrl     (idu1_out),
          .out          (mul_wb_data),
          .out_rd_addr  (mul_wb_rd_addr),
          .out_rd_wr_en (mul_wb_rd_wr_en),
          .mul_busy     (exu_mul_busy)
`ifndef SYNTHESIS
          ,
          .instr_tag_out(mul_instr_tag_out),
          .instr_out    (mul_instr_out)
`endif
      );
    end else begin
      assign mul_wb_data    = '0;
      assign mul_wb_rd_addr = '0;
      assign mul_wb_rd_wr_en = 1'b0;
      assign exu_mul_busy   = 1'b0;
`ifndef SYNTHESIS
      assign mul_instr_tag_out = '0;
      assign mul_instr_out     = '0;
`endif
    end

    if (HAS_DIV != 0) begin
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
          .div_stall               (exu_div_busy)
`ifndef SYNTHESIS
          ,
          .instr_out     (div_instr_out),
          .instr_tag_out (div_instr_tag_out)
`endif
      );
    end else begin
      assign div_wb_data    = '0;
      assign div_wb_rd_addr = '0;
      assign div_wb_rd_wr_en = 1'b0;
      assign exu_div_busy   = 1'b0;
`ifndef SYNTHESIS
      assign div_instr_tag_out = '0;
      assign div_instr_out     = '0;
`endif
    end

    if (HAS_LSU != 0) begin
      lsu lsu_inst (
          .clk                (clk),
          .rstn               (rstn),
          .lsu_ctrl           (idu1_out),
          .lsu_wb_data        (lsu_wb_data),
          .lsu_wb_rd_addr     (lsu_wb_rd_addr),
          .lsu_wb_rd_wr_en    (lsu_wb_rd_wr_en),
          .lsu_busy           (exu_lsu_busy),
          .lsu_stall          (exu_lsu_stall),
          .lsu_dccm_raddr     (dccm_raddr),
          .lsu_dccm_rvalid_in (dccm_rvalid_in),
          .lsu_dccm_rdata     (dccm_rdata),
          .lsu_dccm_rvalid_out(dccm_rvalid_out),
          .lsu_dccm_waddr     (dccm_waddr),
          .lsu_dccm_wen       (dccm_wen),
          .lsu_dccm_wdata     (dccm_wdata)
`ifndef SYNTHESIS
          ,
          .instr_tag_out            (lsu_instr_tag_out),
          .instr_out                (lsu_instr_out),
          .debug_store_dc2_valid    (lsu_debug_store_dc2_valid),
          .debug_store_dc2_instr_tag(lsu_debug_store_dc2_instr_tag),
          .debug_store_dc2_instr    (lsu_debug_store_dc2_instr),
          .debug_store_dc2_addr     (lsu_debug_store_dc2_addr),
          .debug_store_dc2_wdata    (lsu_debug_store_dc2_wdata),
          .debug_store_dc3_valid    (lsu_debug_store_dc3_valid),
          .debug_store_dc3_instr_tag(lsu_debug_store_dc3_instr_tag),
          .debug_store_dc3_instr    (lsu_debug_store_dc3_instr),
          .debug_store_dc3_addr     (lsu_debug_store_dc3_addr),
          .debug_store_dc3_wdata    (lsu_debug_store_dc3_wdata)
`endif
      );
    end else begin
      assign lsu_wb_data     = '0;
      assign lsu_wb_rd_addr  = '0;
      assign lsu_wb_rd_wr_en = 1'b0;
      assign exu_lsu_busy    = 1'b0;
      assign exu_lsu_stall   = 1'b0;
      assign dccm_raddr      = '0;
      assign dccm_rvalid_in  = 1'b0;
      assign dccm_waddr      = '0;
      assign dccm_wen        = 1'b0;
      assign dccm_wdata      = '0;
`ifndef SYNTHESIS
      assign lsu_instr_tag_out             = '0;
      assign lsu_instr_out                 = '0;
      assign lsu_debug_store_dc2_valid     = 1'b0;
      assign lsu_debug_store_dc2_instr_tag = '0;
      assign lsu_debug_store_dc2_instr     = '0;
      assign lsu_debug_store_dc2_addr      = '0;
      assign lsu_debug_store_dc2_wdata     = '0;
      assign lsu_debug_store_dc3_valid     = 1'b0;
      assign lsu_debug_store_dc3_instr_tag = '0;
      assign lsu_debug_store_dc3_instr     = '0;
      assign lsu_debug_store_dc3_addr      = '0;
      assign lsu_debug_store_dc3_wdata     = '0;
`endif
    end
  endgenerate

`ifndef SYNTHESIS
  /* ECALL retire tracking for simulation only */
  register_sync_rstn #(
      .WIDTH($bits({idu1_out.ecall, idu1_out.instr_tag, idu1_out.instr}))
  ) ecall_reg (
      .clk (clk),
      .rstn(rstn),
      .din ({idu1_out.ecall & idu1_out.legal, idu1_out.instr_tag, idu1_out.instr}),
      .dout({ecall_exe, ecall_instr_tag_out, ecall_instr_out})
  );
`endif

  assign exu_wb_data = ({XLEN{alu_wb_rd_wr_en}} & alu_wb_data) |
                       ({XLEN{mul_wb_rd_wr_en}} & mul_wb_data) |
                       ({XLEN{div_wb_rd_wr_en}} & div_wb_data) |
                       ({XLEN{lsu_wb_rd_wr_en}} & lsu_wb_data);

  assign exu_wb_rd_addr = ({REG_FILE_ADDR_WIDTH{alu_wb_rd_wr_en}} & alu_wb_rd_addr) |
                          ({REG_FILE_ADDR_WIDTH{mul_wb_rd_wr_en}} & mul_wb_rd_addr) |
                          ({REG_FILE_ADDR_WIDTH{div_wb_rd_wr_en}} & div_wb_rd_addr) |
                          ({REG_FILE_ADDR_WIDTH{lsu_wb_rd_wr_en}} & lsu_wb_rd_addr);

  assign exu_wb_rd_wr_en = alu_wb_rd_wr_en | mul_wb_rd_wr_en | div_wb_rd_wr_en | lsu_wb_rd_wr_en;

`ifndef SYNTHESIS
  assign instr_tag_out = ({XLEN{alu_wb_rd_wr_en}} & alu_instr_tag_out) |
                         ({XLEN{mul_wb_rd_wr_en}} & mul_instr_tag_out) |
                         ({XLEN{div_wb_rd_wr_en}} & div_instr_tag_out) |
                         ({XLEN{lsu_wb_rd_wr_en}} & lsu_instr_tag_out) |
                         ({XLEN{ecall_exe}} & ecall_instr_tag_out);

  assign instr_out = ({INSTR_LEN{alu_wb_rd_wr_en}} & alu_instr_out) |
                     ({INSTR_LEN{mul_wb_rd_wr_en}} & mul_instr_out) |
                     ({INSTR_LEN{div_wb_rd_wr_en}} & div_instr_out) |
                     ({INSTR_LEN{lsu_wb_rd_wr_en}} & lsu_instr_out) |
                     ({INSTR_LEN{ecall_exe}} & ecall_instr_out);

  assign debug.reg_wr              = exu_wb_rd_wr_en & ~pc_load;
  assign debug.reg_wr_jal            = exu_wb_rd_wr_en & pc_load;
  assign debug.br_taken              = (HAS_ALU != 0) & ~alu_wb_rd_wr_en & pc_load;
  assign debug.br_not_taken          = (HAS_ALU != 0) & alu_debug_br_not_taken;
  assign debug.mem_store             = (HAS_LSU != 0) & lsu_debug_store_dc2_valid;
  assign debug.mem_store_unaligned   = (HAS_LSU != 0) & lsu_debug_store_dc3_valid;
  assign debug.ecall                 = ecall_exe;

  assign debug.wb_instr_tag = instr_tag_out;
  assign debug.wb_instr     = instr_out;
  assign debug.wb_rd_addr   = exu_wb_rd_addr;
  assign debug.wb_data      = exu_wb_data;
  assign debug.wb_pc        = pc_out;

  assign debug.br_taken_instr_tag = alu_instr_tag_out;
  assign debug.br_taken_instr     = alu_instr_out;
  assign debug.br_taken_pc        = pc_out;

  assign debug.br_not_taken_instr_tag = alu_debug_br_not_taken_instr_tag;
  assign debug.br_not_taken_instr     = alu_debug_br_not_taken_instr;

  assign debug.mem_store_instr_tag = lsu_debug_store_dc2_instr_tag;
  assign debug.mem_store_instr     = lsu_debug_store_dc2_instr;
  assign debug.mem_store_addr      = lsu_debug_store_dc2_addr;
  assign debug.mem_store_wdata     = lsu_debug_store_dc2_wdata;

  assign debug.mem_store_unaligned_instr_tag = lsu_debug_store_dc3_instr_tag;
  assign debug.mem_store_unaligned_instr     = lsu_debug_store_dc3_instr;
  assign debug.mem_store_unaligned_addr      = lsu_debug_store_dc3_addr;
  assign debug.mem_store_unaligned_wdata     = lsu_debug_store_dc3_wdata;

  assign debug.ecall_instr_tag = ecall_instr_tag_out;
  assign debug.ecall_instr     = ecall_instr_out;
`endif

endmodule
