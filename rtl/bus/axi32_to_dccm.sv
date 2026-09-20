///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// One 32-bit AXI4 master (INCR, SIZE=4B) as a 128-bit DCCM narrow client.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi32_to_dccm (
    input logic clk,
    input logic rstn,

    input  logic [   AXI_ID_WIDTH-1:0] s_axi_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s_axi_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s_axi_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s_axi_arburst,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,
    output logic [   AXI_ID_WIDTH-1:0] s_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]  s_axi_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] s_axi_rresp,
    output logic                        s_axi_rlast,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready,

    input  logic [   AXI_ID_WIDTH-1:0] s_axi_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s_axi_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s_axi_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s_axi_awburst,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  s_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,
    output logic [   AXI_ID_WIDTH-1:0] s_axi_bid,
    output logic [ AXI_RESP_WIDTH-1:0] s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,

    input  logic              dccm_gnt,
    output logic              dccm_req,
    output logic              dccm_wen,
    output logic [      31:0] dccm_addr,
    output logic [     127:0] dccm_wdata,
    output logic [      15:0] dccm_wstrb,
    input  logic [     127:0] dccm_rdata,
    input  logic              dccm_rvalid
);

  typedef enum logic [1:0] { S_IDLE, S_READ, S_WRITE, S_B } st_e;
  st_e st;

  logic [31:0] addr_q;
  logic [7:0]  left_q;
  logic [AXI_ID_WIDTH-1:0] id_q;
  logic        rd_pend;
  logic        rhold;
  logic [31:0] rdata_q;

  logic [1:0] sl;
  assign sl = addr_q[3:2];

  assign s_axi_arready = (st == S_IDLE) && !s_axi_awvalid;
  assign s_axi_awready = (st == S_IDLE) && s_axi_awvalid;
  assign s_axi_wready  = (st == S_WRITE) && dccm_gnt;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_bresp   = 2'b00;
  assign s_axi_rid     = id_q;
  assign s_axi_bid     = id_q;
  assign s_axi_rdata   = rdata_q;
  assign s_axi_rlast   = (left_q == 8'd0);
  assign s_axi_rvalid  = (st == S_READ) && rhold;

  assign dccm_req   = ((st == S_READ) && !rd_pend && !rhold) ||
                      ((st == S_WRITE) && s_axi_wvalid);
  assign dccm_wen   = (st == S_WRITE);
  assign dccm_addr  = {addr_q[31:4], 4'd0};
  assign dccm_wdata = {96'd0, s_axi_wdata} << {sl, 5'd0};
  assign dccm_wstrb = {12'd0, s_axi_wstrb} << {sl, 2'b00};

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st      <= S_IDLE;
      addr_q  <= 32'd0;
      left_q  <= 8'd0;
      id_q    <= '0;
      rd_pend <= 1'b0;
      rhold   <= 1'b0;
      rdata_q <= 32'd0;
      s_axi_bvalid <= 1'b0;
    end else begin
      unique case (st)
        S_IDLE: begin
          s_axi_bvalid <= 1'b0;
          rd_pend      <= 1'b0;
          rhold        <= 1'b0;
          if (s_axi_awvalid && s_axi_awready) begin
            addr_q <= s_axi_awaddr;
            left_q <= s_axi_awlen;
            id_q   <= s_axi_awid;
            st     <= S_WRITE;
          end else if (s_axi_arvalid && s_axi_arready) begin
            addr_q <= s_axi_araddr;
            left_q <= s_axi_arlen;
            id_q   <= s_axi_arid;
            st     <= S_READ;
          end
        end
        S_READ: begin
          if (dccm_req && dccm_gnt) rd_pend <= 1'b1;
          if (dccm_rvalid) begin
            rd_pend <= 1'b0;
            rhold   <= 1'b1;
            rdata_q <= dccm_rdata[{sl, 5'd0}+:32];
          end
          if (s_axi_rvalid && s_axi_rready) begin
            rhold <= 1'b0;
            if (left_q == 8'd0) begin
              st <= S_IDLE;
            end else begin
              left_q <= left_q - 8'd1;
              addr_q <= addr_q + 32'd4;
            end
          end
        end
        S_WRITE: begin
          if (s_axi_wvalid && s_axi_wready) begin
            if (s_axi_wlast || left_q == 8'd0) begin
              st           <= S_B;
              s_axi_bvalid <= 1'b1;
            end else begin
              left_q <= left_q - 8'd1;
              addr_q <= addr_q + 32'd4;
            end
          end
        end
        S_B: begin
          if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            st           <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  logic _unused_axi;
  assign _unused_axi = &{1'b0, s_axi_arsize, s_axi_arburst, s_axi_awsize, s_axi_awburst};

endmodule
