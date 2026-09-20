///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Unified 128-bit DCCM: exclusive 3:1 mux + host 32-bit narrow port.
// Host address is a 32-bit word index (line = addr[17:2], slot = addr[1:0]).

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module soc_dccm #(
    parameter int DEPTH = 65536,
    parameter int WIDTH = 128,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic rstn,

    input  logic              s_req,
    input  logic              s_wen,
    input  logic [      31:0] s_addr,
    input  logic [     127:0] s_wdata,
    input  logic [      15:0] s_wstrb,
    output logic [     127:0] s_rdata,
    output logic              s_rvalid,

    input  logic              v_req,
    input  logic              v_wen,
    input  logic [      31:0] v_addr,
    input  logic [     127:0] v_wdata,
    input  logic [      15:0] v_wstrb,
    output logic [     127:0] v_rdata,
    output logic              v_rvalid,

    input  logic              g_req,
    input  logic              g_wen,
    input  logic [      31:0] g_addr,
    input  logic [     127:0] g_wdata,
    input  logic [      15:0] g_wstrb,
    output logic [     127:0] g_rdata,
    output logic              g_rvalid,

    input  logic        host_sel,
    input  logic        host_en,
    input  logic        host_wr,
    input  logic [31:0] host_addr,
    input  logic [31:0] host_din,
    input  logic [ 3:0] host_wstrb,
    output logic [31:0] host_dout,
    output logic        host_rvalid
);

  localparam int LINE_AW = $clog2(DEPTH);

  logic              mux_en;
  logic [      15:0] mux_we;
  logic [      31:0] mux_addr;
  logic [     127:0] mux_wdata;
  logic [     127:0] ram_doa, ram_dob;

  logic [1:0]              host_slot;
  logic [1:0]              host_slot_q;
  logic [LINE_AW-1:0]      host_line;
  logic [          15:0]   host_we;
  logic [         127:0]   host_wdata;

  assign host_slot  = host_addr[1:0];
  assign host_line  = host_addr[LINE_AW+1:2];
  assign host_we    = {12'd0, host_wstrb} << {host_slot, 2'b00};
  assign host_wdata = {96'd0, host_din} << {host_slot, 5'd0};

  dccm_mux u_mux (
      .clk      (clk),
      .rstn     (rstn),
      .s_req    (s_req),
      .s_wen    (s_wen),
      .s_addr   (s_addr),
      .s_wdata  (s_wdata),
      .s_wstrb  (s_wstrb),
      .s_rdata  (s_rdata),
      .s_rvalid (s_rvalid),
      .v_req    (v_req),
      .v_wen    (v_wen),
      .v_addr   (v_addr),
      .v_wdata  (v_wdata),
      .v_wstrb  (v_wstrb),
      .v_rdata  (v_rdata),
      .v_rvalid (v_rvalid),
      .g_req    (g_req),
      .g_wen    (g_wen),
      .g_addr   (g_addr),
      .g_wdata  (g_wdata),
      .g_wstrb  (g_wstrb),
      .g_rdata  (g_rdata),
      .g_rvalid (g_rvalid),
      .host_sel (host_sel),
      .ram_en   (mux_en),
      .ram_we   (mux_we),
      .ram_addr (mux_addr),
      .ram_wdata(mux_wdata),
      .ram_rdata(ram_doa)
  );

  sync_tdp_mem #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH),
      .INIT_FILE(INIT_FILE)
  ) u_mem (
      .clka (clk),
      .clkb (clk),
      .ena  (mux_en),
      .enb  (host_sel && host_en),
      .wea  (mux_we),
      .web  ({16{host_sel && host_wr}} & host_we),
      .addra(mux_addr[LINE_AW+3:4]),
      .addrb(host_line),
      .dia  (mux_wdata),
      .dib  (host_wdata),
      .doa  (ram_doa),
      .dob  (ram_dob)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      host_rvalid <= 1'b0;
      host_slot_q <= 2'd0;
    end else begin
      host_rvalid <= host_sel && host_en && !host_wr;
      if (host_sel && host_en && !host_wr) host_slot_q <= host_slot;
    end
  end

  assign host_dout = ram_dob[{host_slot_q, 5'd0}+:32];

endmodule
