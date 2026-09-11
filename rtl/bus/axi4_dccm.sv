///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// AXI4 slave around byte-write DCCM. Handles LEN=0 and LEN=1 INCR bursts.

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

  logic        rd_active;
  logic [7:0]  rd_len;
  logic [7:0]  rd_beat;
  logic [AXI_ID_WIDTH-1:0] rd_id;
  logic [AXI_ADDR_WIDTH-1:0] rd_addr;

  logic ar_fire;
  logic r_fire;
  assign ar_fire = s_axi_arvalid & s_axi_arready;
  assign r_fire  = s_axi_rvalid & s_axi_rready;
  assign s_axi_arready = ~rd_active | (r_fire & s_axi_rlast);

  logic [WORD_AW-1:0] dccm_raddr;
  logic               dccm_rvalid_in;
  logic [WIDTH-1:0]   dccm_rdata;
  logic               dccm_rvalid_out;

  assign dccm_raddr = ar_fire ? s_axi_araddr[WORD_AW+1:2] :
                      (rd_active ? rd_addr[WORD_AW+1:2] : '0);
  assign dccm_rvalid_in = ar_fire | (rd_active & r_fire & ~s_axi_rlast);

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

  assign s_axi_rid    = rd_id;
  assign s_axi_rdata  = dccm_rdata;
  assign s_axi_rresp  = AXI_RESP_OKAY;
  assign s_axi_rlast  = dccm_rvalid_out & (rd_beat == rd_len);
  assign s_axi_rvalid = dccm_rvalid_out;

  logic        wr_active;
  logic        wr_have_aw;
  logic [7:0]  wr_len;
  logic [7:0]  wr_beat;
  logic [AXI_ID_WIDTH-1:0] wr_id;
  logic [AXI_ADDR_WIDTH-1:0] wr_addr;
  logic        b_pend;

  logic aw_fire;
  logic w_fire;
  logic b_fire;
  assign aw_fire = s_axi_awvalid & s_axi_awready;
  assign w_fire  = s_axi_wvalid & s_axi_wready;
  assign b_fire  = s_axi_bvalid & s_axi_bready;

  /* Do not stall AW/W on B: LSU issues back-to-back beats (unaligned stores)
   * and expects 1-cycle BRAM writes. BREADY is always 1 from the adapter. */
  assign s_axi_awready = ~wr_have_aw;
  assign s_axi_wready  = (wr_have_aw | s_axi_awvalid);

  logic [WORD_AW-1:0] dccm_waddr;
  logic               dccm_wen;
  logic [WIDTH-1:0]   dccm_wdata;
  logic [WIDTH/8-1:0] dccm_wstrb;

  logic [AXI_ADDR_WIDTH-1:0] wr_addr_now;
  assign wr_addr_now = wr_have_aw ? wr_addr : s_axi_awaddr;
  assign dccm_waddr  = wr_addr_now[WORD_AW+1:2];
  assign dccm_wen    = w_fire;
  assign dccm_wdata  = s_axi_wdata;
  assign dccm_wstrb  = s_axi_wstrb;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_active  <= 1'b0;
      wr_have_aw <= 1'b0;
      wr_len     <= '0;
      wr_beat    <= '0;
      wr_id      <= '0;
      wr_addr    <= '0;
      b_pend     <= 1'b0;
    end else begin
      if (aw_fire) begin
        wr_have_aw <= 1'b1;
        wr_active  <= 1'b1;
        wr_len     <= s_axi_awlen;
        wr_id      <= s_axi_awid;
        wr_addr    <= s_axi_awaddr;
        wr_beat    <= '0;
      end

      if (w_fire) begin
        wr_addr <= wr_addr_now + 32'd4;
        wr_beat <= wr_beat + 8'd1;
        if (s_axi_wlast || (wr_have_aw && (wr_beat == wr_len)) ||
            (aw_fire && (s_axi_awlen == 8'd0))) begin
          wr_have_aw <= 1'b0;
          wr_active  <= 1'b0;
          b_pend     <= 1'b1;
        end
      end

      /* Keep B outstanding if a new write completes the same cycle B is taken. */
      if (b_fire && !(w_fire && (s_axi_wlast || (wr_have_aw && (wr_beat == wr_len)) ||
                                 (aw_fire && (s_axi_awlen == 8'd0))))) begin
        b_pend <= 1'b0;
      end
    end
  end

  assign s_axi_bid    = wr_id;
  assign s_axi_bresp  = AXI_RESP_OKAY;
  assign s_axi_bvalid = b_pend;

  logic [WIDTH-1:0] ram_doa;
  logic [WIDTH-1:0] ram_dob;
  logic               ram_ena;
  logic               ram_enb;
  logic [WIDTH/8-1:0] ram_wea;
  logic [WIDTH/8-1:0] ram_web;
  logic [WORD_AW-1:0] ram_addra;
  logic [WORD_AW-1:0] ram_addrb;
  logic [WIDTH-1:0]   ram_dia;
  logic [WIDTH-1:0]   ram_dib;

  assign ram_ena   = host_sel ? 1'b0 : dccm_rvalid_in;
  assign ram_addra = dccm_raddr;
  assign ram_wea   = '0;
  assign ram_dia   = '0;

  assign ram_enb   = host_sel ? host_en : dccm_wen;
  assign ram_web   = host_sel ? ({(WIDTH/8){host_wr}} & host_wstrb)
                              : ({(WIDTH/8){dccm_wen}} & dccm_wstrb);
  assign ram_addrb = host_sel ? host_addr : dccm_waddr;
  assign ram_dib   = host_sel ? host_din : dccm_wdata;

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
    if (!rstn) dccm_rvalid_out <= 1'b0;
    else       dccm_rvalid_out <= ram_ena;
  end
  assign dccm_rdata = ram_doa;

  always_ff @(posedge clk) begin
    if (!rstn) host_rvalid <= 1'b0;
    else       host_rvalid <= host_sel & host_en & ~host_wr;
  end
  assign host_dout = ram_dob;

  logic unused_ax = &{1'b0, s_axi_arsize, s_axi_arburst, s_axi_awsize, s_axi_awburst, wr_active};

endmodule
