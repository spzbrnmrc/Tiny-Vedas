///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Two 32-bit GEMM AXI masters share one exclusive 128-bit DCCM client.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module gemm_dccm_pair (
    input logic clk,
    input logic rstn,

    input  logic [   AXI_ID_WIDTH-1:0] s0_axi_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s0_axi_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s0_axi_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s0_axi_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s0_axi_arburst,
    input  logic                        s0_axi_arvalid,
    output logic                        s0_axi_arready,
    output logic [   AXI_ID_WIDTH-1:0] s0_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]  s0_axi_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] s0_axi_rresp,
    output logic                        s0_axi_rlast,
    output logic                        s0_axi_rvalid,
    input  logic                        s0_axi_rready,
    input  logic [   AXI_ID_WIDTH-1:0] s0_axi_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s0_axi_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s0_axi_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s0_axi_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s0_axi_awburst,
    input  logic                        s0_axi_awvalid,
    output logic                        s0_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  s0_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  s0_axi_wstrb,
    input  logic                        s0_axi_wlast,
    input  logic                        s0_axi_wvalid,
    output logic                        s0_axi_wready,
    output logic [   AXI_ID_WIDTH-1:0] s0_axi_bid,
    output logic [ AXI_RESP_WIDTH-1:0] s0_axi_bresp,
    output logic                        s0_axi_bvalid,
    input  logic                        s0_axi_bready,

    input  logic [   AXI_ID_WIDTH-1:0] s1_axi_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s1_axi_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s1_axi_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s1_axi_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s1_axi_arburst,
    input  logic                        s1_axi_arvalid,
    output logic                        s1_axi_arready,
    output logic [   AXI_ID_WIDTH-1:0] s1_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]  s1_axi_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] s1_axi_rresp,
    output logic                        s1_axi_rlast,
    output logic                        s1_axi_rvalid,
    input  logic                        s1_axi_rready,
    input  logic [   AXI_ID_WIDTH-1:0] s1_axi_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s1_axi_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s1_axi_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s1_axi_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s1_axi_awburst,
    input  logic                        s1_axi_awvalid,
    output logic                        s1_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  s1_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  s1_axi_wstrb,
    input  logic                        s1_axi_wlast,
    input  logic                        s1_axi_wvalid,
    output logic                        s1_axi_wready,
    output logic [   AXI_ID_WIDTH-1:0] s1_axi_bid,
    output logic [ AXI_RESP_WIDTH-1:0] s1_axi_bresp,
    output logic                        s1_axi_bvalid,
    input  logic                        s1_axi_bready,

    output logic              dccm_req,
    output logic              dccm_wen,
    output logic [      31:0] dccm_addr,
    output logic [     127:0] dccm_wdata,
    output logic [      15:0] dccm_wstrb,
    input  logic [     127:0] dccm_rdata,
    input  logic              dccm_rvalid
);

  logic        r0, w0, r1, w1;
  logic        gnt0, gnt1;
  logic        last0;
  logic        gnt0_rd_q, gnt1_rd_q;
  logic [31:0] a0, a1;
  logic [127:0] d0, d1;
  logic [15:0] s0, s1;
  logic        rv0, rv1;

  axi32_to_dccm u_m0 (
      .clk(clk),
      .rstn(rstn),
      .s_axi_arid(s0_axi_arid),
      .s_axi_araddr(s0_axi_araddr),
      .s_axi_arlen(s0_axi_arlen),
      .s_axi_arsize(s0_axi_arsize),
      .s_axi_arburst(s0_axi_arburst),
      .s_axi_arvalid(s0_axi_arvalid),
      .s_axi_arready(s0_axi_arready),
      .s_axi_rid(s0_axi_rid),
      .s_axi_rdata(s0_axi_rdata),
      .s_axi_rresp(s0_axi_rresp),
      .s_axi_rlast(s0_axi_rlast),
      .s_axi_rvalid(s0_axi_rvalid),
      .s_axi_rready(s0_axi_rready),
      .s_axi_awid(s0_axi_awid),
      .s_axi_awaddr(s0_axi_awaddr),
      .s_axi_awlen(s0_axi_awlen),
      .s_axi_awsize(s0_axi_awsize),
      .s_axi_awburst(s0_axi_awburst),
      .s_axi_awvalid(s0_axi_awvalid),
      .s_axi_awready(s0_axi_awready),
      .s_axi_wdata(s0_axi_wdata),
      .s_axi_wstrb(s0_axi_wstrb),
      .s_axi_wlast(s0_axi_wlast),
      .s_axi_wvalid(s0_axi_wvalid),
      .s_axi_wready(s0_axi_wready),
      .s_axi_bid(s0_axi_bid),
      .s_axi_bresp(s0_axi_bresp),
      .s_axi_bvalid(s0_axi_bvalid),
      .s_axi_bready(s0_axi_bready),
      .dccm_gnt(gnt0),
      .dccm_req(r0),
      .dccm_wen(w0),
      .dccm_addr(a0),
      .dccm_wdata(d0),
      .dccm_wstrb(s0),
      .dccm_rdata(dccm_rdata),
      .dccm_rvalid(rv0)
  );

  axi32_to_dccm u_m1 (
      .clk(clk),
      .rstn(rstn),
      .s_axi_arid(s1_axi_arid),
      .s_axi_araddr(s1_axi_araddr),
      .s_axi_arlen(s1_axi_arlen),
      .s_axi_arsize(s1_axi_arsize),
      .s_axi_arburst(s1_axi_arburst),
      .s_axi_arvalid(s1_axi_arvalid),
      .s_axi_arready(s1_axi_arready),
      .s_axi_rid(s1_axi_rid),
      .s_axi_rdata(s1_axi_rdata),
      .s_axi_rresp(s1_axi_rresp),
      .s_axi_rlast(s1_axi_rlast),
      .s_axi_rvalid(s1_axi_rvalid),
      .s_axi_rready(s1_axi_rready),
      .s_axi_awid(s1_axi_awid),
      .s_axi_awaddr(s1_axi_awaddr),
      .s_axi_awlen(s1_axi_awlen),
      .s_axi_awsize(s1_axi_awsize),
      .s_axi_awburst(s1_axi_awburst),
      .s_axi_awvalid(s1_axi_awvalid),
      .s_axi_awready(s1_axi_awready),
      .s_axi_wdata(s1_axi_wdata),
      .s_axi_wstrb(s1_axi_wstrb),
      .s_axi_wlast(s1_axi_wlast),
      .s_axi_wvalid(s1_axi_wvalid),
      .s_axi_wready(s1_axi_wready),
      .s_axi_bid(s1_axi_bid),
      .s_axi_bresp(s1_axi_bresp),
      .s_axi_bvalid(s1_axi_bvalid),
      .s_axi_bready(s1_axi_bready),
      .dccm_gnt(gnt1),
      .dccm_req(r1),
      .dccm_wen(w1),
      .dccm_addr(a1),
      .dccm_wdata(d1),
      .dccm_wstrb(s1),
      .dccm_rdata(dccm_rdata),
      .dccm_rvalid(rv1)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      last0     <= 1'b0;
      gnt0_rd_q <= 1'b0;
      gnt1_rd_q <= 1'b0;
    end else begin
      if (r0 && r1) last0 <= ~last0;
      gnt0_rd_q <= gnt0 && !w0;
      gnt1_rd_q <= gnt1 && !w1;
    end
  end

  assign gnt0 = r0 && (!r1 || last0);
  assign gnt1 = r1 && (!r0 || !last0);

  assign dccm_req   = r0 || r1;
  assign dccm_wen   = (gnt0 && w0) || (gnt1 && w1);
  assign dccm_addr  = gnt1 ? a1 : a0;
  assign dccm_wdata = gnt1 ? d1 : d0;
  assign dccm_wstrb = gnt1 ? s1 : s0;
  assign rv0        = dccm_rvalid && gnt0_rd_q;
  assign rv1        = dccm_rvalid && gnt1_rd_q;

endmodule
