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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Register Scoreboard
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

module rsb #(
    parameter integer N_REG = 32
) (
    input logic clk,
    input logic rstn,

    input logic pipe_flush,

    /* Read Ports */
    input logic [$clog2(N_REG)-1:0] rs1_addr,
    input logic [$clog2(N_REG)-1:0] rs2_addr,
    input logic                     rs1_rd_en,
    input logic                     rs2_rd_en,

    output logic rs1_hit,
    output logic rs2_hit,

    /* Write Ports */
    input logic [$clog2(N_REG)-1:0] set_rd_addr,
    input logic                     set_rd_wr_en,
    input logic [$clog2(N_REG)-1:0] clear_rd_addr,
    input logic                     clear_rd_wr_en
);

  logic [N_REG-1:0] rsb;

  genvar i;

  generate
    for (i = 0; i < N_REG; i++) begin : g_rsb
      logic din;
      assign din = set_rd_wr_en & (set_rd_addr == i) ? 1'b1 : 1'b0;
      if (i == 0) begin : g_zero_reg
        assign rsb[i] = 1'b0;
      end else begin : g_rsb_gen
        register_en_sync_rstn #(
            .WIDTH(1),
            .RESET_VAL(0)
        ) rsb_i (
            .clk (clk),
            .rstn(rstn & (~pipe_flush)),
            .en  (set_rd_wr_en & (set_rd_addr == i) | clear_rd_wr_en & (clear_rd_addr == i)),
            .din (din),
            .dout(rsb[i])
        );
      end
    end
  endgenerate

  assign rs1_hit = (rs1_rd_en) ? rsb[rs1_addr] : 1'b0;
  assign rs2_hit = (rs2_rd_en) ? rsb[rs2_addr] : 1'b0;

endmodule
