///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Pack the core's two 32-bit LSU ports onto one 128-bit DCCM client.
// Same-line unaligned pairs become one beat. Line-crossing is sequential
// in the LSU (word0[3:2]==3); this bridge then sees one port per cycle.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module lsu_dccm_bridge (
    input logic clk,
    input logic rstn,

    input  logic [XLEN-1:0] lsu_raddr     [1:0],
    input  logic            lsu_rvalid_in [1:0],
    output logic [XLEN-1:0] lsu_rdata     [1:0],
    output logic            lsu_rvalid_out[1:0],
    input  logic [XLEN-1:0] lsu_waddr     [1:0],
    input  logic            lsu_wen       [1:0],
    input  logic [XLEN-1:0] lsu_wdata     [1:0],
    input  logic [     3:0] lsu_wstrb     [1:0],

    output logic              dccm_req,
    output logic              dccm_wen,
    output logic [      31:0] dccm_addr,
    output logic [     127:0] dccm_wdata,
    output logic [      15:0] dccm_wstrb,
    input  logic [     127:0] dccm_rdata,
    input  logic              dccm_rvalid
);

  function automatic logic [1:0] slot(input logic [31:0] a);
    return a[3:2];
  endfunction

  function automatic logic [15:0] lane_strb(input logic [3:0] s, input logic [1:0] sl);
    return {12'd0, s} << {sl, 2'b00};
  endfunction

  function automatic logic [127:0] lane_data(input logic [31:0] d, input logic [1:0] sl);
    return {96'd0, d} << {sl, 5'd0};
  endfunction

  logic        rd0, rd1, wr0, wr1;
  logic [31:0] rline;
  logic [1:0]  rslot0, rslot1;
  logic [1:0]  rslot0_q, rslot1_q;
  logic        rd0_q, rd1_q;

  assign rd0 = lsu_rvalid_in[0];
  assign rd1 = lsu_rvalid_in[1];
  assign wr0 = lsu_wen[0];
  assign wr1 = lsu_wen[1];

  assign rline  = rd0 ? {lsu_raddr[0][31:4], 4'd0} :
                  rd1 ? {lsu_raddr[1][31:4], 4'd0} : 32'd0;
  assign rslot0 = slot(lsu_raddr[0]);
  assign rslot1 = slot(lsu_raddr[1]);

  logic [31:0] wline;
  logic [15:0] wstrb;
  logic [127:0] wdata;

  always_comb begin
    wline = wr1 ? {lsu_waddr[1][31:4], 4'd0} :
            wr0 ? {lsu_waddr[0][31:4], 4'd0} : 32'd0;
    wstrb = 16'd0;
    wdata = 128'd0;
    if (wr1) begin
      wstrb |= lane_strb(lsu_wstrb[1], slot(lsu_waddr[1]));
      wdata |= lane_data(lsu_wdata[1], slot(lsu_waddr[1]));
    end
    if (wr0) begin
      wstrb |= lane_strb(lsu_wstrb[0], slot(lsu_waddr[0]));
      wdata |= lane_data(lsu_wdata[0], slot(lsu_waddr[0]));
    end
  end

  assign dccm_req   = rd0 || rd1 || wr0 || wr1;
  assign dccm_wen   = wr0 || wr1;
  assign dccm_addr  = (wr0 || wr1) ? wline : rline;
  assign dccm_wdata = wdata;
  assign dccm_wstrb = wstrb;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rd0_q    <= 1'b0;
      rd1_q    <= 1'b0;
      rslot0_q <= 2'd0;
      rslot1_q <= 2'd0;
    end else begin
      rd0_q    <= rd0;
      rd1_q    <= rd1;
      rslot0_q <= rslot0;
      rslot1_q <= rslot1;
    end
  end

  assign lsu_rdata[0]      = dccm_rdata[{rslot0_q, 5'd0}+:32];
  assign lsu_rdata[1]      = dccm_rdata[{rslot1_q, 5'd0}+:32];
  assign lsu_rvalid_out[0] = dccm_rvalid && rd0_q;
  assign lsu_rvalid_out[1] = dccm_rvalid && rd1_q;

endmodule
