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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Memory Library
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

/* ************** Memory Library ************** */

/**** Instruction Closely Coupled Memory ************** */

/* Word-aligned RV32 fetch only (no next-line peek). 1-cycle read latency.
 * Optional write port for FPGA halt-and-load; sim ties wen=0 and uses INIT_FILE. */
module iccm #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = ""
) (

    input logic clk,
    input logic rstn,

    /* Read Port — byte address, word-aligned */
    input  logic [($clog2(DEPTH*WIDTH/8))-1:0] raddr,
    input  logic                               rvalid_in,
    input  logic [    INSTR_MEM_TAG_WIDTH-1:0] rtag_in,
    output logic [                  WIDTH-1:0] rdata,
    output logic                               rvalid_out,
    output logic [    INSTR_MEM_TAG_WIDTH-1:0] rtag_out,

    /* Write Port — word index + byte strobes (tie off in sim) */
    input logic                     wen,
    input logic [$clog2(DEPTH)-1:0] waddr,
    input logic [        WIDTH-1:0] wdata,
    input logic [      WIDTH/8-1:0] wstrb
);

  localparam int AW = $clog2(DEPTH);
  localparam int BYTE_AW = $clog2(DEPTH * WIDTH / 8);

  (* ram_style = "block" *) logic [WIDTH-1:0] mem[DEPTH];

  logic [AW-1:0] word_idx;
  assign word_idx = raddr[BYTE_AW-1:$clog2(WIDTH/8)];

  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  always_ff @(posedge clk) begin
    if (wen) begin
      if (wstrb[0]) mem[waddr][7:0]   <= wdata[7:0];
      if (wstrb[1]) mem[waddr][15:8]  <= wdata[15:8];
      if (wstrb[2]) mem[waddr][23:16] <= wdata[23:16];
      if (wstrb[3]) mem[waddr][31:24] <= wdata[31:24];
    end
  end

  logic [WIDTH-1:0] rdata_din;
  assign rdata_din = rvalid_in ? mem[word_idx] : '0;

  register_sync_rstn #(
      .WIDTH(1)
  ) rvalid_ff (
      .clk (clk),
      .rstn(rstn),
      .din (rvalid_in),
      .dout(rvalid_out)
  );

  register_sync_rstn #(
      .WIDTH(WIDTH)
  ) rdata_ff (
      .clk (clk),
      .rstn(rstn),
      .din (rdata_din),
      .dout(rdata)
  );

  register_sync_rstn #(
      .WIDTH(INSTR_MEM_TAG_WIDTH)
  ) rtag_ff (
      .clk (clk),
      .rstn(rstn),
      .din (rvalid_in ? rtag_in : {INSTR_MEM_TAG_WIDTH{1'b0}}),
      .dout(rtag_out)
  );

endmodule

/**** Data Closely Coupled Memory ************** */

/* Only read and write ports */
module dccm #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic rstn,

    /* Read Port */
    input  logic [$clog2(DEPTH)-1:0] raddr,
    input  logic                     rvalid_in,
    output logic [        WIDTH-1:0] rdata,
    output logic                     rvalid_out,

    /* Write Port */
    input logic [$clog2(DEPTH)-1:0] waddr,
    input logic                     wen,
    input logic [        WIDTH-1:0] wdata
);

  sync_rw_mem_rstn #(
      .DEPTH    (DEPTH),
      .WIDTH    (WIDTH),
      .INIT_FILE(INIT_FILE)
  ) mem_core (
      .clk        (clk),
      .rstn       (rstn),
      .raddr      (raddr),
      .rvalid_in  (rvalid_in),
      .rdata      (rdata),
      .rvalid_out (rvalid_out),
      .waddr      (waddr),
      .wen        (wen),
      .wdata      (wdata)
  );

endmodule
