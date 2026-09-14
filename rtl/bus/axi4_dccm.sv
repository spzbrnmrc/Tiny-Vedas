///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Dual AXI4 slaves around a true dual-port DCCM.
//   Slave 0 -> TDP port A (core LSU port 0)
//   Slave 1 -> TDP port B (core LSU port 1), muxed with host when host_sel.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_dccm #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic rstn,

    /* AXI slave 0 (TDP port A) */
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

    /* AXI slave 1 (TDP port B / core, muxed with host) */
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

    input  logic                     host_sel,
    input  logic                     host_en,
    input  logic                     host_wr,
    input  logic [$clog2(DEPTH)-1:0] host_addr,
    input  logic [        WIDTH-1:0] host_din,
    input  logic [      WIDTH/8-1:0] host_wstrb,
    output logic [        WIDTH-1:0] host_dout,
    output logic                     host_rvalid
);

  localparam int WORD_AW = $clog2(DEPTH);

  logic               ram_ena, ram_enb;
  logic [WIDTH/8-1:0] ram_wea, ram_web;
  logic [WORD_AW-1:0] ram_addra, ram_addrb;
  logic [WIDTH-1:0]   ram_dia, ram_dib, ram_doa, ram_dob;

  logic               p0_en, p1_en;
  logic [WIDTH/8-1:0] p0_we, p1_we;
  logic [WORD_AW-1:0] p0_addr, p1_addr;
  logic [WIDTH-1:0]   p0_di, p1_di;

  axi4_tdp_port #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH)
  ) u_p0 (
      .clk          (clk),
      .rstn         (rstn),
      .port_enable  (1'b1),
      .s_axi_arid   (s_axi_arid),
      .s_axi_araddr (s_axi_araddr),
      .s_axi_arlen  (s_axi_arlen),
      .s_axi_arvalid(s_axi_arvalid),
      .s_axi_arready(s_axi_arready),
      .s_axi_rid    (s_axi_rid),
      .s_axi_rdata  (s_axi_rdata),
      .s_axi_rresp  (s_axi_rresp),
      .s_axi_rlast  (s_axi_rlast),
      .s_axi_rvalid (s_axi_rvalid),
      .s_axi_rready (s_axi_rready),
      .s_axi_awid   (s_axi_awid),
      .s_axi_awaddr (s_axi_awaddr),
      .s_axi_awlen  (s_axi_awlen),
      .s_axi_awvalid(s_axi_awvalid),
      .s_axi_awready(s_axi_awready),
      .s_axi_wdata  (s_axi_wdata),
      .s_axi_wstrb  (s_axi_wstrb),
      .s_axi_wlast  (s_axi_wlast),
      .s_axi_wvalid (s_axi_wvalid),
      .s_axi_wready (s_axi_wready),
      .s_axi_bid    (s_axi_bid),
      .s_axi_bresp  (s_axi_bresp),
      .s_axi_bvalid (s_axi_bvalid),
      .s_axi_bready (s_axi_bready),
      .ram_en       (p0_en),
      .ram_we       (p0_we),
      .ram_addr     (p0_addr),
      .ram_di       (p0_di),
      .ram_do       (ram_doa)
  );

  axi4_tdp_port #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH)
  ) u_p1 (
      .clk          (clk),
      .rstn         (rstn),
      .port_enable  (~host_sel),
      .s_axi_arid   (s1_axi_arid),
      .s_axi_araddr (s1_axi_araddr),
      .s_axi_arlen  (s1_axi_arlen),
      .s_axi_arvalid(s1_axi_arvalid),
      .s_axi_arready(s1_axi_arready),
      .s_axi_rid    (s1_axi_rid),
      .s_axi_rdata  (s1_axi_rdata),
      .s_axi_rresp  (s1_axi_rresp),
      .s_axi_rlast  (s1_axi_rlast),
      .s_axi_rvalid (s1_axi_rvalid),
      .s_axi_rready (s1_axi_rready),
      .s_axi_awid   (s1_axi_awid),
      .s_axi_awaddr (s1_axi_awaddr),
      .s_axi_awlen  (s1_axi_awlen),
      .s_axi_awvalid(s1_axi_awvalid),
      .s_axi_awready(s1_axi_awready),
      .s_axi_wdata  (s1_axi_wdata),
      .s_axi_wstrb  (s1_axi_wstrb),
      .s_axi_wlast  (s1_axi_wlast),
      .s_axi_wvalid (s1_axi_wvalid),
      .s_axi_wready (s1_axi_wready),
      .s_axi_bid    (s1_axi_bid),
      .s_axi_bresp  (s1_axi_bresp),
      .s_axi_bvalid (s1_axi_bvalid),
      .s_axi_bready (s1_axi_bready),
      .ram_en       (p1_en),
      .ram_we       (p1_we),
      .ram_addr     (p1_addr),
      .ram_di       (p1_di),
      .ram_do       (ram_dob)
  );

  assign ram_ena   = p0_en;
  assign ram_wea   = p0_we;
  assign ram_addra = p0_addr;
  assign ram_dia   = p0_di;

  /* Host vs core mux on TDP port B. Host only while the core is halted. */
  assign ram_enb   = host_sel ? host_en : p1_en;
  assign ram_web   = host_sel ? ({(WIDTH/8){host_wr}} & host_wstrb) : p1_we;
  assign ram_addrb = host_sel ? host_addr : p1_addr;
  assign ram_dib   = host_sel ? host_din : p1_di;

  sync_tdp_mem #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH),
      .INIT_FILE(INIT_FILE)
  ) u_mem (
      .clka (clk),
      .clkb (clk),
      .ena  (ram_ena),
      .enb  (ram_enb),
      .wea  (ram_wea),
      .web  (ram_web),
      .addra(ram_addra),
      .addrb(ram_addrb),
      .dia  (ram_dia),
      .dib  (ram_dib),
      .doa  (ram_doa),
      .dob  (ram_dob)
  );

  always_ff @(posedge clk) begin
    if (!rstn) host_rvalid <= 1'b0;
    else       host_rvalid <= host_sel & host_en & ~host_wr;
  end
  assign host_dout = ram_dob;

  logic unused_ax = &{1'b0, s_axi_arsize, s_axi_arburst, s_axi_awsize, s_axi_awburst,
                       s1_axi_arsize, s1_axi_arburst, s1_axi_awsize, s1_axi_awburst};

endmodule
