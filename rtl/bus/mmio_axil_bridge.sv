///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// LSU MMIO (store pulse + load request) -> AXI-lite master for one device.

`timescale 1ns / 1ps

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module mmio_axil_bridge (
    input logic clk,
    input logic rstn,

    input  logic        wr_valid,
    input  logic [31:0] wr_addr,
    input  logic [31:0] wr_data,
    input  logic        rd_valid,
    input  logic [31:0] rd_addr,
    output logic [31:0] rd_data,
    output logic        rd_ready,

    output logic [AXI_ADDR_WIDTH-1:0] m_axil_awaddr,
    output logic                      m_axil_awvalid,
    input  logic                      m_axil_awready,
    output logic [AXI_DATA_WIDTH-1:0] m_axil_wdata,
    output logic [AXI_STRB_WIDTH-1:0] m_axil_wstrb,
    output logic                      m_axil_wvalid,
    input  logic                      m_axil_wready,
    input  logic [AXI_RESP_WIDTH-1:0] m_axil_bresp,
    input  logic                      m_axil_bvalid,
    output logic                      m_axil_bready,
    output logic [AXI_ADDR_WIDTH-1:0] m_axil_araddr,
    output logic                      m_axil_arvalid,
    input  logic                      m_axil_arready,
    input  logic [AXI_DATA_WIDTH-1:0] m_axil_rdata,
    input  logic [AXI_RESP_WIDTH-1:0] m_axil_rresp,
    input  logic                      m_axil_rvalid,
    output logic                      m_axil_rready
);

  logic        wr_hold;
  logic [31:0] wr_addr_q, wr_data_q;
  logic        rd_hold;
  logic [31:0] rd_addr_q;

  logic wr_fire, rd_fire;

  assign wr_fire = (wr_valid | wr_hold) & m_axil_awready & m_axil_wready;
  assign rd_fire = (rd_valid | rd_hold) & m_axil_arready & ~m_axil_rvalid;

  assign m_axil_awaddr  = wr_hold ? wr_addr_q : wr_addr;
  assign m_axil_wdata   = wr_hold ? wr_data_q : wr_data;
  assign m_axil_wstrb   = 4'hF;
  assign m_axil_awvalid = wr_valid | wr_hold;
  assign m_axil_wvalid  = wr_valid | wr_hold;
  assign m_axil_bready  = 1'b1;

  assign m_axil_araddr  = rd_hold ? rd_addr_q : rd_addr;
  assign m_axil_arvalid = (rd_valid | rd_hold) & ~m_axil_rvalid;
  assign m_axil_rready  = 1'b1;

  assign rd_data  = m_axil_rdata;
  assign rd_ready = m_axil_rvalid;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_hold   <= 1'b0;
      wr_addr_q <= '0;
      wr_data_q <= '0;
      rd_hold   <= 1'b0;
      rd_addr_q <= '0;
    end else begin
      if ((wr_valid | wr_hold) && !wr_fire) begin
        wr_hold   <= 1'b1;
        wr_addr_q <= wr_valid ? wr_addr : wr_addr_q;
        wr_data_q <= wr_valid ? wr_data : wr_data_q;
      end else if (wr_fire) begin
        wr_hold <= 1'b0;
      end

      if ((rd_valid | rd_hold) && !rd_fire && !m_axil_rvalid) begin
        rd_hold   <= 1'b1;
        rd_addr_q <= rd_valid ? rd_addr : rd_addr_q;
      end else if (rd_fire || m_axil_rvalid) begin
        rd_hold <= 1'b0;
      end
    end
  end

  logic unused = &{1'b0, m_axil_bresp, m_axil_bvalid, m_axil_rresp};

endmodule
