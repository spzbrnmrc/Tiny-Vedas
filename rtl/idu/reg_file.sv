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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Register File
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

module reg_file #(
    parameter logic   [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h80000000,
    parameter integer            N_RPORTS_PAIRS           = 1,
    parameter integer            N_WPORTS                 = 1
) (
    input logic clk,
    input logic rstn,

    /* Read Ports */
    input  logic [REG_FILE_ADDR_WIDTH-1:0] rs1_addr [N_RPORTS_PAIRS-1:0],
    input  logic [REG_FILE_ADDR_WIDTH-1:0] rs2_addr [N_RPORTS_PAIRS-1:0],
    input  logic                           rs1_rd_en[N_RPORTS_PAIRS-1:0],
    input  logic                           rs2_rd_en[N_RPORTS_PAIRS-1:0],
    output logic [               XLEN-1:0] rs1_data [N_RPORTS_PAIRS-1:0],
    output logic [               XLEN-1:0] rs2_data [N_RPORTS_PAIRS-1:0],

    /* Write Ports */
    input logic [N_WPORTS-1:0][REG_FILE_ADDR_WIDTH-1:0] rd_addr,
    input logic [N_WPORTS-1:0][               XLEN-1:0] rd_data,
    input logic [N_WPORTS-1:0]                          rd_wr_en
);

  logic [XLEN-1:0] reg_file[REG_FILE_DEPTH];

  genvar i, wp;
  /* Write */

  generate
    for (i = 0; i < REG_FILE_DEPTH; i++) begin : g_reg_file
      if (i == 0) begin : g_zero_reg
        assign reg_file[i] = '0;
      end else begin : g_reg_file_gen
        logic [N_WPORTS-1:0] wr_sel;
        logic                wr_en;
        logic [    XLEN-1:0] wr_data;

        for (wp = 0; wp < N_WPORTS; wp++) begin : g_wr_sel
          assign wr_sel[wp] = rd_wr_en[wp] & (rd_addr[wp] == REG_FILE_ADDR_WIDTH'(i));
        end

        assign wr_en = |wr_sel;

        always_comb begin
          wr_data = '0;
          for (int w = 0; w < N_WPORTS; w++) begin
            if (wr_sel[w]) wr_data = rd_data[w];
          end
        end

        register_en_sync_rstn #(
            .WIDTH(XLEN),
            .RESET_VAL((i == 2) ? STACK_POINTER_INIT_VALUE : 0)
        ) reg_i (
            .clk (clk),
            .rstn(rstn),
            .en  (wr_en),
            .din (wr_data),
            .dout(reg_file[i])
        );
      end
    end
  endgenerate

`ifndef SYNTHESIS
  always_comb begin
    if (rstn) begin
      for (int addr = 0; addr < REG_FILE_DEPTH; addr++) begin
        automatic int active = 0;
        for (int w = 0; w < N_WPORTS; w++) begin
          if (rd_wr_en[w] && (rd_addr[w] == REG_FILE_ADDR_WIDTH'(addr))) active++;
        end
        assert (active <= 1)
        else $error("reg_file: multiple write ports active for x%0d", addr);
      end
    end
  end
`endif

  /* Read */

  genvar rp;
  generate
    for (rp = 0; rp < N_RPORTS_PAIRS; rp++) begin : g_rp
      assign rs1_data[rp] = (rs1_rd_en[rp]) ? reg_file[rs1_addr[rp]] : {XLEN{1'b0}};
      assign rs2_data[rp] = (rs2_rd_en[rp]) ? reg_file[rs2_addr[rp]] : {XLEN{1'b0}};
    end
  endgenerate

endmodule
