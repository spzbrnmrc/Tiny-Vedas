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
// Tiny-Vedas FPGA shell control/status (AXI4-Lite slave).
// Verilog-2001 — required for Vivado BD module reference.
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module vedas_shell_ctrl #(
    parameter [31:0] VERSION = 32'h000A_0001
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);

  // 0x00 VERSION (RO), 0x04 SCRATCH (RW), 0x08 HEARTBEAT (RO)

  reg [31:0] scratch;
  reg [31:0] heartbeat;

  wire aw_hs;
  wire w_hs;
  wire ar_hs;
  wire write_en;

  assign aw_hs    = s_axi_awvalid & s_axi_awready;
  assign w_hs     = s_axi_wvalid & s_axi_wready;
  assign ar_hs    = s_axi_arvalid & s_axi_arready;
  assign write_en = aw_hs & w_hs;

  assign s_axi_awready = s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
  assign s_axi_wready  = s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
  assign s_axi_arready = s_axi_arvalid & ~s_axi_rvalid;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      scratch      <= 32'h0;
      heartbeat    <= 32'h0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      s_axi_rvalid <= 1'b0;
      s_axi_rresp  <= 2'b00;
      s_axi_rdata  <= 32'h0;
    end else begin
      heartbeat <= heartbeat + 32'h1;

      if (write_en) begin
        if (s_axi_awaddr[7:0] == 8'h04) begin
          if (s_axi_wstrb[0]) scratch[7:0]   <= s_axi_wdata[7:0];
          if (s_axi_wstrb[1]) scratch[15:8]  <= s_axi_wdata[15:8];
          if (s_axi_wstrb[2]) scratch[23:16] <= s_axi_wdata[23:16];
          if (s_axi_wstrb[3]) scratch[31:24] <= s_axi_wdata[31:24];
        end
        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (ar_hs) begin
        s_axi_rvalid <= 1'b1;
        s_axi_rresp  <= 2'b00;
        case (s_axi_araddr[7:0])
          8'h00:   s_axi_rdata <= VERSION;
          8'h04:   s_axi_rdata <= scratch;
          8'h08:   s_axi_rdata <= heartbeat;
          default: s_axi_rdata <= 32'hDEAD_BEEF;
        endcase
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
