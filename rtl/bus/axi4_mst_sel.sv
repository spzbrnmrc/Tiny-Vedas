///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Select between two AXI4 masters onto one slave. sel=1 uses master B.

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_mst_sel (
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

  assign s_arid    = sel_b ? b_arid : a_arid;
  assign s_araddr  = sel_b ? b_araddr : a_araddr;
  assign s_arlen   = sel_b ? b_arlen : a_arlen;
  assign s_arsize  = sel_b ? b_arsize : a_arsize;
  assign s_arburst = sel_b ? b_arburst : a_arburst;
  assign s_arvalid = sel_b ? b_arvalid : a_arvalid;
  assign a_arready = sel_b ? 1'b0 : s_arready;
  assign b_arready = sel_b ? s_arready : 1'b0;

  assign a_rid   = s_rid;
  assign a_rdata = s_rdata;
  assign a_rresp = s_rresp;
  assign a_rlast = s_rlast;
  assign a_rvalid = sel_b ? 1'b0 : s_rvalid;
  assign b_rid   = s_rid;
  assign b_rdata = s_rdata;
  assign b_rresp = s_rresp;
  assign b_rlast = s_rlast;
  assign b_rvalid = sel_b ? s_rvalid : 1'b0;
  assign s_rready = sel_b ? b_rready : a_rready;

  assign s_awid    = sel_b ? b_awid : a_awid;
  assign s_awaddr  = sel_b ? b_awaddr : a_awaddr;
  assign s_awlen   = sel_b ? b_awlen : a_awlen;
  assign s_awsize  = sel_b ? b_awsize : a_awsize;
  assign s_awburst = sel_b ? b_awburst : a_awburst;
  assign s_awvalid = sel_b ? b_awvalid : a_awvalid;
  assign a_awready = sel_b ? 1'b0 : s_awready;
  assign b_awready = sel_b ? s_awready : 1'b0;

  assign s_wdata  = sel_b ? b_wdata : a_wdata;
  assign s_wstrb  = sel_b ? b_wstrb : a_wstrb;
  assign s_wlast  = sel_b ? b_wlast : a_wlast;
  assign s_wvalid = sel_b ? b_wvalid : a_wvalid;
  assign a_wready = sel_b ? 1'b0 : s_wready;
  assign b_wready = sel_b ? s_wready : 1'b0;

  assign a_bid   = s_bid;
  assign a_bresp = s_bresp;
  assign a_bvalid = sel_b ? 1'b0 : s_bvalid;
  assign b_bid   = s_bid;
  assign b_bresp = s_bresp;
  assign b_bvalid = sel_b ? s_bvalid : 1'b0;
  assign s_bready = sel_b ? b_bready : a_bready;

endmodule
