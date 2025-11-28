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
    parameter logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h80000000
) (
    input logic clk,
    input logic rstn,

    /* Read Ports */
    input  logic [REG_FILE_ADDR_WIDTH-1:0] rs1_addr,
    input  logic [REG_FILE_ADDR_WIDTH-1:0] rs2_addr,
    input  logic                           rs1_rd_en,
    input  logic                           rs2_rd_en,
    output logic [               XLEN-1:0] rs1_data,
    output logic [               XLEN-1:0] rs2_data,

    /* Write Ports */
    input logic [REG_FILE_ADDR_WIDTH-1:0] rd_addr,
    input logic [               XLEN-1:0] rd_data,
    input logic                           rd_wr_en
);

  logic [XLEN-1:0] reg_file[REG_FILE_DEPTH];

  genvar i;

  generate
    for (i = 0; i < REG_FILE_DEPTH; i++) begin : g_reg_file
      if (i == 0) begin : g_zero_reg
        assign reg_file[i] = 0;
      end else begin : g_reg_file_gen
        register_en_sync_rstn #(
            .WIDTH(XLEN),
            .RESET_VAL((i == 2) ? STACK_POINTER_INIT_VALUE : 0)
        ) reg_i (
            .clk (clk),
            .rstn(rstn),
            .en  (rd_wr_en & (rd_addr == i)),
            .din (rd_data),
            .dout(reg_file[i])
        );
      end
    end
  endgenerate

  assign rs1_data = (rs1_rd_en) ? reg_file[rs1_addr] : {XLEN{1'b0}};
  assign rs2_data = (rs2_rd_en) ? reg_file[rs2_addr] : {XLEN{1'b0}};

endmodule
