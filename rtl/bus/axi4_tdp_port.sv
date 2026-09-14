///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// One AXI4 slave bound to a single TDP RAM port (RW). LEN=0 and LEN=1 INCR.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_tdp_port #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32
) (
    input logic clk,
    input logic rstn,
    input logic port_enable,

    input  logic [   AXI_ID_WIDTH-1:0] s_axi_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s_axi_arlen,
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

    output logic                     ram_en,
    output logic [        WIDTH/8-1:0] ram_we,
    output logic [$clog2(DEPTH)-1:0] ram_addr,
    output logic [        WIDTH-1:0] ram_di,
    input  logic [        WIDTH-1:0] ram_do
);

  localparam int WORD_AW = $clog2(DEPTH);

  logic        rd_active;
  logic [7:0]  rd_len;
  logic [7:0]  rd_beat;
  logic [AXI_ID_WIDTH-1:0] rd_id;
  logic [AXI_ADDR_WIDTH-1:0] rd_addr;
  logic        rd_data_valid;

  logic        wr_have_aw;
  logic [7:0]  wr_len;
  logic [7:0]  wr_beat;
  logic [AXI_ID_WIDTH-1:0] wr_id;
  logic [AXI_ADDR_WIDTH-1:0] wr_addr;
  logic        b_pend;

  logic ar_fire;
  logic r_fire;
  logic aw_fire;
  logic w_fire;
  logic b_fire;
  logic wr_last_beat;

  assign r_fire  = s_axi_rvalid & s_axi_rready;
  /* Same-cycle AR as last R beat, like the previous single-port DCCM slave. */
  assign s_axi_arready = port_enable & (~rd_active | (r_fire & s_axi_rlast)) & ~s_axi_wvalid;
  assign ar_fire = s_axi_arvalid & s_axi_arready;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rd_active     <= 1'b0;
      rd_len        <= '0;
      rd_beat       <= '0;
      rd_id         <= '0;
      rd_addr       <= '0;
      rd_data_valid <= 1'b0;
    end else begin
      rd_data_valid <= ar_fire | (rd_active & r_fire & ~s_axi_rlast);
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
  assign s_axi_rdata  = ram_do;
  assign s_axi_rresp  = AXI_RESP_OKAY;
  assign s_axi_rlast  = rd_data_valid & (rd_beat == rd_len);
  assign s_axi_rvalid = rd_data_valid;

  assign s_axi_awready = port_enable & ~wr_have_aw & ~rd_active;
  assign s_axi_wready  = port_enable & (wr_have_aw | s_axi_awvalid) & ~rd_active;
  assign aw_fire = s_axi_awvalid & s_axi_awready;
  assign w_fire  = s_axi_wvalid & s_axi_wready;
  assign b_fire  = s_axi_bvalid & s_axi_bready;

  logic [AXI_ADDR_WIDTH-1:0] wr_addr_now;
  assign wr_addr_now = wr_have_aw ? wr_addr : s_axi_awaddr;
  assign wr_last_beat = w_fire & (s_axi_wlast || (wr_have_aw && (wr_beat == wr_len)) ||
                                  (aw_fire && (s_axi_awlen == 8'd0)));

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_have_aw <= 1'b0;
      wr_len     <= '0;
      wr_beat    <= '0;
      wr_id      <= '0;
      wr_addr    <= '0;
      b_pend     <= 1'b0;
    end else begin
      if (aw_fire) begin
        wr_have_aw <= 1'b1;
        wr_len     <= s_axi_awlen;
        wr_id      <= s_axi_awid;
        wr_addr    <= s_axi_awaddr;
        wr_beat    <= '0;
      end
      if (w_fire) begin
        wr_addr <= wr_addr_now + 32'd4;
        wr_beat <= wr_beat + 8'd1;
        if (wr_last_beat) begin
          wr_have_aw <= 1'b0;
          b_pend     <= 1'b1;
        end
      end
      if (b_fire && !wr_last_beat) begin
        b_pend <= 1'b0;
      end
    end
  end

  assign s_axi_bid    = wr_id;
  assign s_axi_bresp  = AXI_RESP_OKAY;
  assign s_axi_bvalid = b_pend;

  logic [WORD_AW-1:0] rd_word;
  logic [WORD_AW-1:0] wr_word;
  assign rd_word = ar_fire ? s_axi_araddr[WORD_AW+1:2] :
                   (rd_active ? rd_addr[WORD_AW+1:2] : '0);
  assign wr_word = wr_addr_now[WORD_AW+1:2];

  assign ram_en   = ar_fire | (rd_active & r_fire & ~s_axi_rlast) | w_fire;
  assign ram_we   = w_fire ? s_axi_wstrb : '0;
  assign ram_addr = w_fire ? wr_word : rd_word;
  assign ram_di   = s_axi_wdata;

endmodule
