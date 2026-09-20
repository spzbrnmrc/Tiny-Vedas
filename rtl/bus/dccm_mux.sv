///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Exclusive 3:1 grant onto one 128-bit DCCM port.
// Pipeline law: at most one of {scalar, vector, gemm} requests.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module dccm_mux (
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

    input  logic              host_sel,
    output logic              ram_en,
    output logic [      15:0] ram_we,
    output logic [      31:0] ram_addr,
    output logic [     127:0] ram_wdata,
    input  logic [     127:0] ram_rdata
);

  logic        gnt_s, gnt_v, gnt_g;
  logic        gnt_s_q, gnt_v_q, gnt_g_q;

  assign gnt_g = g_req && !host_sel;
  assign gnt_v = v_req && !host_sel && !g_req;
  assign gnt_s = s_req && !host_sel && !g_req && !v_req;

  assign ram_en = (gnt_s || gnt_v || gnt_g) && !host_sel;
  assign ram_we = ({16{gnt_g && g_wen}} & g_wstrb) |
                  ({16{gnt_v && v_wen}} & v_wstrb) |
                  ({16{gnt_s && s_wen}} & s_wstrb);
  assign ram_addr = ({32{gnt_g}} & g_addr) |
                    ({32{gnt_v}} & v_addr) |
                    ({32{gnt_s}} & s_addr);
  assign ram_wdata = ({128{gnt_g}} & g_wdata) |
                     ({128{gnt_v}} & v_wdata) |
                     ({128{gnt_s}} & s_wdata);

  always_ff @(posedge clk) begin
    if (!rstn) begin
      gnt_s_q <= 1'b0;
      gnt_v_q <= 1'b0;
      gnt_g_q <= 1'b0;
    end else begin
      gnt_s_q <= gnt_s && !s_wen;
      gnt_v_q <= gnt_v && !v_wen;
      gnt_g_q <= gnt_g && !g_wen;
    end
  end

  assign s_rdata  = ram_rdata;
  assign v_rdata  = ram_rdata;
  assign g_rdata  = ram_rdata;
  assign s_rvalid = gnt_s_q;
  assign v_rvalid = gnt_v_q;
  assign g_rvalid = gnt_g_q;

endmodule
