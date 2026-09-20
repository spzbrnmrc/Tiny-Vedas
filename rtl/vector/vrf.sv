///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// 32 vregs × VLMAX e32, 4 banks (addr[1:0]). One write per bank so FPGA
// infers distributed RAM. Async read. No reset (a reset loop forces flops).

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module vrf #(
    parameter int unsigned N_VREG   = 32,
    parameter int unsigned VLMAX    = 16,
    parameter int unsigned N_RPORTS = 8,
    parameter int unsigned N_WPORTS = 4,
    parameter int unsigned N_ELEM   = N_VREG * VLMAX,
    parameter int unsigned VRF_AW   = $clog2(N_ELEM)
) (
    input logic clk,
    input logic rstn,

    input  logic [N_RPORTS-1:0][VRF_AW-1:0] raddr,
    output logic [N_RPORTS-1:0][     31:0] rdata,

    input logic [N_WPORTS-1:0][VRF_AW-1:0] waddr,
    input logic [N_WPORTS-1:0]             wen,
    input logic [N_WPORTS-1:0][     31:0] wdata
);

  localparam int unsigned N_BANKS = 4;
  localparam int unsigned BANK_AW = VRF_AW - 2;
  localparam int unsigned BANK_D  = N_ELEM / N_BANKS;

  logic [N_BANKS-1:0]             bwen;
  logic [N_BANKS-1:0][BANK_AW-1:0] bwa;
  logic [N_BANKS-1:0][      31:0] bwd;

  always_comb begin
    bwen = '0;
    bwa  = '0;
    bwd  = '0;
    for (int w = 0; w < int'(N_WPORTS); w++) begin
      if (wen[w]) begin
        bwen[waddr[w][1:0]] = 1'b1;
        bwa[waddr[w][1:0]]  = waddr[w][VRF_AW-1:2];
        bwd[waddr[w][1:0]]  = wdata[w];
      end
    end
  end

  (* ram_style = "distributed" *) logic [31:0] bank0[BANK_D];
  (* ram_style = "distributed" *) logic [31:0] bank1[BANK_D];
  (* ram_style = "distributed" *) logic [31:0] bank2[BANK_D];
  (* ram_style = "distributed" *) logic [31:0] bank3[BANK_D];

  always_ff @(posedge clk) begin
    if (bwen[0]) bank0[bwa[0]] <= bwd[0];
  end
  always_ff @(posedge clk) begin
    if (bwen[1]) bank1[bwa[1]] <= bwd[1];
  end
  always_ff @(posedge clk) begin
    if (bwen[2]) bank2[bwa[2]] <= bwd[2];
  end
  always_ff @(posedge clk) begin
    if (bwen[3]) bank3[bwa[3]] <= bwd[3];
  end

  genvar rp;
  generate
    for (rp = 0; rp < int'(N_RPORTS); rp++) begin : g_rp
      always_comb begin
        unique case (raddr[rp][1:0])
          2'd0: rdata[rp] = bank0[raddr[rp][VRF_AW-1:2]];
          2'd1: rdata[rp] = bank1[raddr[rp][VRF_AW-1:2]];
          2'd2: rdata[rp] = bank2[raddr[rp][VRF_AW-1:2]];
          default: rdata[rp] = bank3[raddr[rp][VRF_AW-1:2]];
        endcase
      end
    end
  endgenerate

  logic _unused_rstn;
  assign _unused_rstn = rstn;

endmodule
