///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Custom LSU DCCM port -> AXI4 master. Independent AR vs AW/W.
// Single-beat (LEN=0) transactions; unaligned LSU beats become consecutive singles.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module dmem_to_axi4 (
    input logic clk,
    input logic rstn,

    input  logic [XLEN-1:0] dccm_raddr,
    input  logic            dccm_rvalid_in,
    output logic [XLEN-1:0] dccm_rdata,
    output logic            dccm_rvalid_out,
    input  logic [XLEN-1:0] dccm_waddr,
    input  logic            dccm_wen,
    input  logic [XLEN-1:0] dccm_wdata,
    input  logic [     3:0] dccm_wstrb,

    output logic [   AXI_ID_WIDTH-1:0] m_axi_arid,
    output logic [ AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [   AXI_LEN_WIDTH-1:0] m_axi_arlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m_axi_arsize,
    output logic [ AXI_BURST_WIDTH-1:0] m_axi_arburst,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,
    input  logic [   AXI_ID_WIDTH-1:0] m_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  logic [ AXI_RESP_WIDTH-1:0] m_axi_rresp,
    input  logic                        m_axi_rlast,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rready,

    output logic [   AXI_ID_WIDTH-1:0] m_axi_awid,
    output logic [ AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [   AXI_LEN_WIDTH-1:0] m_axi_awlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m_axi_awsize,
    output logic [ AXI_BURST_WIDTH-1:0] m_axi_awburst,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0]  m_axi_wdata,
    output logic [AXI_STRB_WIDTH-1:0]  m_axi_wstrb,
    output logic                        m_axi_wlast,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wready,
    input  logic [   AXI_ID_WIDTH-1:0] m_axi_bid,
    input  logic [ AXI_RESP_WIDTH-1:0] m_axi_bresp,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_bready
);

  localparam logic [AXI_ID_WIDTH-1:0] DMEM_ID = '0;

  logic        ar_hold;
  logic [XLEN-1:0] ar_addr_q;
  logic        aw_hold;
  logic        w_hold;
  logic [XLEN-1:0] aw_addr_q;
  logic [XLEN-1:0] w_data_q;
  logic [     3:0] w_strb_q;

  logic ar_fire;
  logic aw_fire;
  logic w_fire;

  assign ar_fire = m_axi_arvalid & m_axi_arready;
  assign aw_fire = m_axi_awvalid & m_axi_awready;
  assign w_fire  = m_axi_wvalid & m_axi_wready;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      ar_hold   <= 1'b0;
      ar_addr_q <= '0;
      aw_hold   <= 1'b0;
      w_hold    <= 1'b0;
      aw_addr_q <= '0;
      w_data_q  <= '0;
      w_strb_q  <= '0;
    end else begin
      if (dccm_rvalid_in & ~ar_fire) begin
        ar_hold   <= 1'b1;
        ar_addr_q <= dccm_raddr;
      end else if (ar_fire) begin
        ar_hold <= 1'b0;
      end

      if (dccm_wen & ~aw_fire) begin
        aw_hold   <= 1'b1;
        aw_addr_q <= dccm_waddr;
      end else if (aw_fire) begin
        aw_hold <= 1'b0;
      end

      if (dccm_wen & ~w_fire) begin
        w_hold   <= 1'b1;
        w_data_q <= dccm_wdata;
        w_strb_q <= dccm_wstrb;
      end else if (w_fire) begin
        w_hold <= 1'b0;
      end
    end
  end

  assign m_axi_arid    = DMEM_ID;
  assign m_axi_araddr  = ar_hold ? ar_addr_q : dccm_raddr;
  assign m_axi_arlen   = '0;
  assign m_axi_arsize  = AXI_SIZE_4B;
  assign m_axi_arburst = AXI_BURST_INCR;
  assign m_axi_arvalid = dccm_rvalid_in | ar_hold;
  assign m_axi_rready  = 1'b1;

  assign dccm_rdata      = m_axi_rdata;
  assign dccm_rvalid_out = m_axi_rvalid;

  assign m_axi_awid    = DMEM_ID;
  assign m_axi_awaddr  = aw_hold ? aw_addr_q : dccm_waddr;
  assign m_axi_awlen   = '0;
  assign m_axi_awsize  = AXI_SIZE_4B;
  assign m_axi_awburst = AXI_BURST_INCR;
  assign m_axi_awvalid = dccm_wen | aw_hold;
  assign m_axi_wdata   = w_hold ? w_data_q : dccm_wdata;
  assign m_axi_wstrb   = w_hold ? w_strb_q : dccm_wstrb;
  assign m_axi_wlast   = 1'b1;
  assign m_axi_wvalid  = dccm_wen | w_hold;
  assign m_axi_bready  = 1'b1;

  logic unused_axi = &{1'b0, m_axi_rid, m_axi_rresp, m_axi_rlast, m_axi_bid, m_axi_bresp,
                       m_axi_bvalid};

endmodule
