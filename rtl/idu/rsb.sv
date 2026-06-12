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
    parameter integer N_REG          = 32,
    parameter integer N_RPORTS_PAIRS = 1,
    parameter integer N_WPORTS       = 1
) (
    input logic clk,
    input logic rstn,

    input logic pipe_flush,

    /* Read Ports */
    input  logic [REG_FILE_ADDR_WIDTH-1:0] rs1_addr [N_RPORTS_PAIRS-1:0],
    input  logic [REG_FILE_ADDR_WIDTH-1:0] rs2_addr [N_RPORTS_PAIRS-1:0],
    input  logic                           rs1_rd_en[N_RPORTS_PAIRS-1:0],
    input  logic                           rs2_rd_en[N_RPORTS_PAIRS-1:0],
    output logic                           rs1_hit  [N_RPORTS_PAIRS-1:0],
    output logic                           rs2_hit  [N_RPORTS_PAIRS-1:0],

    /* Write Ports */
    input logic [N_WPORTS-1:0][$clog2(N_REG)-1:0] set_rd_addr,
    input logic [N_WPORTS-1:0]                      set_rd_wr_en,
    input logic [N_WPORTS-1:0][$clog2(N_REG)-1:0] clear_rd_addr,
    input logic [N_WPORTS-1:0]                      clear_rd_wr_en
);

  logic [N_REG-1:0] rsb;

  genvar i, wp, rp;

  generate
    for (i = 0; i < N_REG; i++) begin : g_rsb
      if (i == 0) begin : g_zero_reg
        assign rsb[i] = 1'b0;
      end else begin : g_rsb_gen
        logic [N_WPORTS-1:0] set_sel;
        logic [N_WPORTS-1:0] clear_sel;
        logic                upd_en;
        logic                din;

        for (wp = 0; wp < N_WPORTS; wp++) begin : g_set_sel
          assign set_sel[wp] = set_rd_wr_en[wp] & (set_rd_addr[wp] == $clog2(N_REG)'(i));
        end

        for (wp = 0; wp < N_WPORTS; wp++) begin : g_clear_sel
          assign clear_sel[wp] = clear_rd_wr_en[wp] & (clear_rd_addr[wp] == $clog2(N_REG)'(i));
        end

        assign upd_en = |set_sel | |clear_sel;
        assign din    = |set_sel;

        register_en_sync_rstn #(
            .WIDTH(1),
            .RESET_VAL(0)
        ) rsb_i (
            .clk (clk),
            .rstn(rstn & (~pipe_flush)),
            .en  (upd_en),
            .din (din),
            .dout(rsb[i])
        );
      end
    end
  endgenerate

`ifndef SYNTHESIS
  always_comb begin
    if (rstn) begin
      for (int addr = 0; addr < N_REG; addr++) begin
        automatic int set_active   = 0;
        automatic int clear_active = 0;
        for (int w = 0; w < N_WPORTS; w++) begin
          if (set_rd_wr_en[w] && (set_rd_addr[w] == $clog2(N_REG)'(addr))) set_active++;
          if (clear_rd_wr_en[w] && (clear_rd_addr[w] == $clog2(N_REG)'(addr))) clear_active++;
        end
        assert (set_active <= 1)
        else $error("rsb: multiple set ports active for x%0d", addr);
        assert (clear_active <= 1)
        else $error("rsb: multiple clear ports active for x%0d", addr);
      end
    end
  end
`endif

  generate
    for (rp = 0; rp < N_RPORTS_PAIRS; rp++) begin : g_rp
      assign rs1_hit[rp] = (rs1_rd_en[rp]) ? rsb[rs1_addr[rp]] : 1'b0;
      assign rs2_hit[rp] = (rs2_rd_en[rp]) ? rsb[rs2_addr[rp]] : 1'b0;
    end
  endgenerate

endmodule
