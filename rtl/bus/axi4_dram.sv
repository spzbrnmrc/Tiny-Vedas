///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Dual-port AXI4 (LEN=0) DRAM stub. 1-cycle read, posted write.
// Host side-port is used only while the core is halted (FPGA preload).

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_dram #(
    parameter int DEPTH = 4194304,
    parameter logic [31:0] BASE = 32'h40000000,
    parameter string INIT_FILE = ""
) (
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

    input  logic        host_en,
    input  logic        host_wr,
    input  logic [31:0] host_addr,
    input  logic [31:0] host_din,
    input  logic [ 3:0] host_wstrb,
    output logic [31:0] host_dout,
    output logic        host_rvalid
);

  localparam int WORD_AW = $clog2(DEPTH);

  function automatic logic [WORD_AW-1:0] word_idx(input logic [31:0] addr);
    logic [31:0] off;
    off = addr - BASE;
    return off[WORD_AW+1:2];
  endfunction

  logic                    ena, enb;
  logic [           3:0]   wea, web;
  logic [WORD_AW-1:0]      addra, addrb;
  logic [          31:0]   dia, dib, doa, dob;

  logic        s1_busy;
  assign s1_busy = host_en;

  logic        rd0_pend, rd1_pend;
  logic [AXI_ID_WIDTH-1:0] rid0_q, rid1_q;
  logic        wr0_pend, wr1_pend;
  logic [AXI_ID_WIDTH-1:0] bid0_q, bid1_q;

  assign s0_axi_arready = ~rd0_pend | (s0_axi_rvalid & s0_axi_rready);
  assign s1_axi_arready = ~s1_busy & (~rd1_pend | (s1_axi_rvalid & s1_axi_rready));
  assign s0_axi_awready = ~wr0_pend | (s0_axi_bvalid & s0_axi_bready);
  assign s0_axi_wready  = s0_axi_awready;
  assign s1_axi_awready = ~s1_busy & (~wr1_pend | (s1_axi_bvalid & s1_axi_bready));
  assign s1_axi_wready  = s1_axi_awready;

  logic s0_ar_fire, s1_ar_fire, s0_wr_fire, s1_wr_fire;
  assign s0_ar_fire = s0_axi_arvalid & s0_axi_arready;
  assign s1_ar_fire = s1_axi_arvalid & s1_axi_arready;
  assign s0_wr_fire = s0_axi_awvalid & s0_axi_awready & s0_axi_wvalid & s0_axi_wready;
  assign s1_wr_fire = s1_axi_awvalid & s1_axi_awready & s1_axi_wvalid & s1_axi_wready;

  always_comb begin
    ena   = s0_ar_fire | s0_wr_fire;
    wea   = s0_wr_fire ? s0_axi_wstrb : 4'h0;
    addra = word_idx(s0_wr_fire ? s0_axi_awaddr : s0_axi_araddr);
    dia   = s0_axi_wdata;

    enb   = host_en ? host_en : (s1_ar_fire | s1_wr_fire);
    web   = host_en ? (host_wr ? host_wstrb : 4'h0) :
            (s1_wr_fire ? s1_axi_wstrb : 4'h0);
    addrb = host_en ? host_addr[WORD_AW+1:2] :
            word_idx(s1_wr_fire ? s1_axi_awaddr : s1_axi_araddr);
    dib   = host_en ? host_din : s1_axi_wdata;
  end

  sync_tdp_mem #(
      .DEPTH(DEPTH),
      .WIDTH(32),
      .INIT_FILE(INIT_FILE),
      .RAM_STYLE("block")
  ) u_ram (
      .clka (clk),
      .clkb (clk),
      .ena  (ena),
      .enb  (enb),
      .wea  (wea),
      .web  (web),
      .addra(addra),
      .addrb(addrb),
      .dia  (dia),
      .dib  (dib),
      .doa  (doa),
      .dob  (dob)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rd0_pend <= 1'b0;
      rd1_pend <= 1'b0;
      wr0_pend <= 1'b0;
      wr1_pend <= 1'b0;
      rid0_q   <= '0;
      rid1_q   <= '0;
      bid0_q   <= '0;
      bid1_q   <= '0;
      host_rvalid <= 1'b0;
      host_dout   <= '0;
    end else begin
      if (s0_ar_fire) begin
        rd0_pend <= 1'b1;
        rid0_q   <= s0_axi_arid;
      end else if (s0_axi_rvalid & s0_axi_rready) begin
        rd0_pend <= 1'b0;
      end

      if (s1_ar_fire) begin
        rd1_pend <= 1'b1;
        rid1_q   <= s1_axi_arid;
      end else if (s1_axi_rvalid & s1_axi_rready) begin
        rd1_pend <= 1'b0;
      end

      if (s0_wr_fire) begin
        wr0_pend <= 1'b1;
        bid0_q   <= s0_axi_awid;
      end else if (s0_axi_bvalid & s0_axi_bready) begin
        wr0_pend <= 1'b0;
      end

      if (s1_wr_fire) begin
        wr1_pend <= 1'b1;
        bid1_q   <= s1_axi_awid;
      end else if (s1_axi_bvalid & s1_axi_bready) begin
        wr1_pend <= 1'b0;
      end

      host_rvalid <= host_en && !host_wr;
      if (host_en && !host_wr) host_dout <= dob;
    end
  end

  assign s0_axi_rvalid = rd0_pend;
  assign s0_axi_rdata  = doa;
  assign s0_axi_rid    = rid0_q;
  assign s0_axi_rresp  = 2'b00;
  assign s0_axi_rlast  = 1'b1;
  assign s0_axi_bvalid = wr0_pend;
  assign s0_axi_bid    = bid0_q;
  assign s0_axi_bresp  = 2'b00;

  assign s1_axi_rvalid = rd1_pend;
  assign s1_axi_rdata  = dob;
  assign s1_axi_rid    = rid1_q;
  assign s1_axi_rresp  = 2'b00;
  assign s1_axi_rlast  = 1'b1;
  assign s1_axi_bvalid = wr1_pend;
  assign s1_axi_bid    = bid1_q;
  assign s1_axi_bresp  = 2'b00;

  logic unused = &{1'b0, s0_axi_arlen, s0_axi_arsize, s0_axi_arburst, s0_axi_awlen,
                   s0_axi_awsize, s0_axi_awburst, s0_axi_wlast,
                   s1_axi_arlen, s1_axi_arsize, s1_axi_arburst, s1_axi_awlen,
                   s1_axi_awsize, s1_axi_awburst, s1_axi_wlast};

endmodule
