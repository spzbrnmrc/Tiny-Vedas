///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// AXI4 slave around ICCM. Fetch on AR/R (LEN=0 or 1). Host write is a side port.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_iccm #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = ""
) (
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

    input logic                     host_wen,
    input logic [$clog2(DEPTH)-1:0] host_waddr,
    input logic [        WIDTH-1:0] host_wdata,
    input logic [      WIDTH/8-1:0] host_wstrb,
    input logic                     host_ren,
    input logic [($clog2(DEPTH*WIDTH/8))-1:0] host_raddr,
    output logic [        WIDTH-1:0] host_rdata,
    output logic                     host_rvalid
);

  localparam int BYTE_AW = $clog2(DEPTH * WIDTH / 8);

  logic        rd_active;
  logic [7:0]  rd_len;
  logic [7:0]  rd_beat;
  logic [AXI_ID_WIDTH-1:0] rd_id;
  logic [AXI_ADDR_WIDTH-1:0] rd_addr;

  logic ar_fire;
  logic r_fire;

  assign ar_fire = s_axi_arvalid & s_axi_arready;
  assign r_fire  = s_axi_rvalid & s_axi_rready;

  /* Accept the next AR on RLAST so fetch stays 1-cycle (IFU PC free-runs). */
  assign s_axi_arready = ~rd_active | (r_fire & s_axi_rlast);

  logic [BYTE_AW-1:0] iccm_raddr;
  logic               iccm_rvalid_in;
  logic [INSTR_MEM_TAG_WIDTH-1:0] iccm_rtag_in;
  logic [WIDTH-1:0] iccm_rdata;
  logic             iccm_rvalid_out;
  logic [INSTR_MEM_TAG_WIDTH-1:0] iccm_rtag_out;

  logic host_rd;
  assign host_rd = host_ren & ~ar_fire & ~rd_active;

  assign iccm_raddr = host_rd ? host_raddr :
                      (ar_fire ? s_axi_araddr[BYTE_AW-1:0] :
                       (rd_active ? rd_addr[BYTE_AW-1:0] : '0));
  assign iccm_rvalid_in = host_rd | ar_fire | (rd_active & r_fire & ~s_axi_rlast);
  assign iccm_rtag_in   = host_rd ? '0 :
      {{(INSTR_MEM_TAG_WIDTH - AXI_ID_WIDTH) {1'b0}},
       (ar_fire ? s_axi_arid : rd_id)};

  iccm #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH),
      .INIT_FILE(INIT_FILE)
  ) u_iccm (
      .clk       (clk),
      .rstn      (rstn),
      .raddr     (iccm_raddr),
      .rvalid_in (iccm_rvalid_in),
      .rtag_in   (iccm_rtag_in),
      .rdata     (iccm_rdata),
      .rvalid_out(iccm_rvalid_out),
      .rtag_out  (iccm_rtag_out),
      .wen       (host_wen),
      .waddr     (host_waddr),
      .wdata     (host_wdata),
      .wstrb     (host_wstrb)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rd_active <= 1'b0;
      rd_len    <= '0;
      rd_beat   <= '0;
      rd_id     <= '0;
      rd_addr   <= '0;
    end else begin
      if (ar_fire) begin
        rd_active <= 1'b1;
        rd_len    <= s_axi_arlen;
        rd_beat   <= '0;
        rd_id     <= s_axi_arid;
        rd_addr   <= s_axi_araddr + 32'd4;
      end else if (r_fire) begin
        if (s_axi_rlast) begin
          rd_active <= 1'b0;
        end else begin
          rd_beat <= rd_beat + 8'd1;
          rd_addr <= rd_addr + 32'd4;
        end
      end
    end
  end

  assign s_axi_rid    = iccm_rtag_out[AXI_ID_WIDTH-1:0];
  assign s_axi_rdata  = iccm_rdata;
  assign s_axi_rresp  = AXI_RESP_OKAY;
  assign s_axi_rlast  = iccm_rvalid_out & (rd_beat == rd_len);
  assign s_axi_rvalid = iccm_rvalid_out & ~host_rvalid;

  always_ff @(posedge clk) begin
    if (!rstn) host_rvalid <= 1'b0;
    else       host_rvalid <= host_rd;
  end
  assign host_rdata = iccm_rdata;

  logic unused_ax = &{1'b0, s_axi_arsize, s_axi_arburst};

endmodule
