///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Select between two AXI4 masters onto one slave. sel_b=1 uses master B.
//
// Select is sticky until the granted master's outstanding AR/R and AW/B
// complete. A combinational cutover (old GEMM mux) lets the new master
// rready=1 drain the slave beat that still belongs to the old master —
// LSU hangs forever, GEMM deadlocks on a leftover wr_have_aw.

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_mst_sel (
    input logic clk,
    input logic rstn,
    input logic sel_b,

    input  logic [   AXI_ID_WIDTH-1:0] a_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] a_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] a_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] a_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] a_arburst,
    input  logic                        a_arvalid,
    output logic                        a_arready,
    output logic [   AXI_ID_WIDTH-1:0] a_rid,
    output logic [AXI_DATA_WIDTH-1:0]  a_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] a_rresp,
    output logic                        a_rlast,
    output logic                        a_rvalid,
    input  logic                        a_rready,
    input  logic [   AXI_ID_WIDTH-1:0] a_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] a_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] a_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] a_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] a_awburst,
    input  logic                        a_awvalid,
    output logic                        a_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  a_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  a_wstrb,
    input  logic                        a_wlast,
    input  logic                        a_wvalid,
    output logic                        a_wready,
    output logic [   AXI_ID_WIDTH-1:0] a_bid,
    output logic [ AXI_RESP_WIDTH-1:0] a_bresp,
    output logic                        a_bvalid,
    input  logic                        a_bready,

    input  logic [   AXI_ID_WIDTH-1:0] b_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] b_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] b_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] b_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] b_arburst,
    input  logic                        b_arvalid,
    output logic                        b_arready,
    output logic [   AXI_ID_WIDTH-1:0] b_rid,
    output logic [AXI_DATA_WIDTH-1:0]  b_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] b_rresp,
    output logic                        b_rlast,
    output logic                        b_rvalid,
    input  logic                        b_rready,
    input  logic [   AXI_ID_WIDTH-1:0] b_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] b_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] b_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] b_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] b_awburst,
    input  logic                        b_awvalid,
    output logic                        b_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  b_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  b_wstrb,
    input  logic                        b_wlast,
    input  logic                        b_wvalid,
    output logic                        b_wready,
    output logic [   AXI_ID_WIDTH-1:0] b_bid,
    output logic [ AXI_RESP_WIDTH-1:0] b_bresp,
    output logic                        b_bvalid,
    input  logic                        b_bready,

    output logic [   AXI_ID_WIDTH-1:0] s_arid,
    output logic [ AXI_ADDR_WIDTH-1:0] s_araddr,
    output logic [   AXI_LEN_WIDTH-1:0] s_arlen,
    output logic [  AXI_SIZE_WIDTH-1:0] s_arsize,
    output logic [ AXI_BURST_WIDTH-1:0] s_arburst,
    output logic                        s_arvalid,
    input  logic                        s_arready,
    input  logic [   AXI_ID_WIDTH-1:0] s_rid,
    input  logic [AXI_DATA_WIDTH-1:0]  s_rdata,
    input  logic [ AXI_RESP_WIDTH-1:0] s_rresp,
    input  logic                        s_rlast,
    input  logic                        s_rvalid,
    output logic                        s_rready,
    output logic [   AXI_ID_WIDTH-1:0] s_awid,
    output logic [ AXI_ADDR_WIDTH-1:0] s_awaddr,
    output logic [   AXI_LEN_WIDTH-1:0] s_awlen,
    output logic [  AXI_SIZE_WIDTH-1:0] s_awsize,
    output logic [ AXI_BURST_WIDTH-1:0] s_awburst,
    output logic                        s_awvalid,
    input  logic                        s_awready,
    output logic [AXI_DATA_WIDTH-1:0]  s_wdata,
    output logic [AXI_STRB_WIDTH-1:0]  s_wstrb,
    output logic                        s_wlast,
    output logic                        s_wvalid,
    input  logic                        s_wready,
    input  logic [   AXI_ID_WIDTH-1:0] s_bid,
    input  logic [ AXI_RESP_WIDTH-1:0] s_bresp,
    input  logic                        s_bvalid,
    output logic                        s_bready
);

  logic sel;
  logic rd_busy;
  logic wr_busy;
  logic rd_start, rd_done;
  logic wr_start, wr_done;

  assign rd_start = s_arvalid & s_arready;
  assign rd_done  = s_rvalid & s_rready & s_rlast;
  assign wr_start = s_awvalid & s_awready;
  assign wr_done  = s_bvalid & s_bready;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      sel     <= 1'b0;
      rd_busy <= 1'b0;
      wr_busy <= 1'b0;
    end else begin
      if (rd_start && !rd_done) rd_busy <= 1'b1;
      else if (rd_done && !rd_start) rd_busy <= 1'b0;

      if (wr_start && !wr_done) wr_busy <= 1'b1;
      else if (wr_done && !wr_start) wr_busy <= 1'b0;

      if (!rd_busy && !wr_busy && !rd_start && !wr_start) sel <= sel_b;
    end
  end

  assign s_arid    = sel ? b_arid : a_arid;
  assign s_araddr  = sel ? b_araddr : a_araddr;
  assign s_arlen   = sel ? b_arlen : a_arlen;
  assign s_arsize  = sel ? b_arsize : a_arsize;
  assign s_arburst = sel ? b_arburst : a_arburst;
  assign s_arvalid = sel ? b_arvalid : a_arvalid;
  assign a_arready = sel ? 1'b0 : s_arready;
  assign b_arready = sel ? s_arready : 1'b0;

  assign a_rid   = s_rid;
  assign a_rdata = s_rdata;
  assign a_rresp = s_rresp;
  assign a_rlast = s_rlast;
  assign a_rvalid = sel ? 1'b0 : s_rvalid;
  assign b_rid   = s_rid;
  assign b_rdata = s_rdata;
  assign b_rresp = s_rresp;
  assign b_rlast = s_rlast;
  assign b_rvalid = sel ? s_rvalid : 1'b0;
  assign s_rready = sel ? b_rready : a_rready;

  assign s_awid    = sel ? b_awid : a_awid;
  assign s_awaddr  = sel ? b_awaddr : a_awaddr;
  assign s_awlen   = sel ? b_awlen : a_awlen;
  assign s_awsize  = sel ? b_awsize : a_awsize;
  assign s_awburst = sel ? b_awburst : a_awburst;
  assign s_awvalid = sel ? b_awvalid : a_awvalid;
  assign a_awready = sel ? 1'b0 : s_awready;
  assign b_awready = sel ? s_awready : 1'b0;

  assign s_wdata  = sel ? b_wdata : a_wdata;
  assign s_wstrb  = sel ? b_wstrb : a_wstrb;
  assign s_wlast  = sel ? b_wlast : a_wlast;
  assign s_wvalid = sel ? b_wvalid : a_wvalid;
  assign a_wready = sel ? 1'b0 : s_wready;
  assign b_wready = sel ? s_wready : 1'b0;

  assign a_bid   = s_bid;
  assign a_bresp = s_bresp;
  assign a_bvalid = sel ? 1'b0 : s_bvalid;
  assign b_bid   = s_bid;
  assign b_bresp = s_bresp;
  assign b_bvalid = sel ? s_bvalid : 1'b0;
  assign s_bready = sel ? b_bready : a_bready;

endmodule
