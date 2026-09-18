///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Output-stationary PE: signed int8 x int8 -> int32 MAC using SVLib Booth mul.

`timescale 1ns / 1ps

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module gemm_pe (
    input  logic        clk,
    input  logic        rstn,
    input  logic        en,
    input  logic        clear,
    input  logic [ 7:0] a,
    input  logic [ 7:0] b,
    output logic [31:0] acc
);

  localparam int SB_LAT = GEMM_MUL_PIPE_LAT + 1;

  logic                  en_q, clear_q;
  logic [           7:0] a_q, b_q;
  logic [           7:0] booth_lower, booth_upper;
  logic signed [    15:0] prod;
  logic signed [    31:0] acc_s;
  logic [    SB_LAT-1:0] en_d, clear_d;

  assign acc  = acc_s;
  assign prod = $signed({booth_upper, booth_lower});

  always_ff @(posedge clk) begin
    if (!rstn) begin
      en_q     <= 1'b0;
      clear_q  <= 1'b0;
      a_q      <= '0;
      b_q      <= '0;
      en_d     <= '0;
      clear_d  <= '0;
    end else begin
      en_q     <= en;
      clear_q  <= clear;
      a_q      <= a;
      b_q      <= b;
      en_d     <= {en_d[SB_LAT-2:0], en_q};
      clear_d  <= {clear_d[SB_LAT-2:0], clear_q};
    end
  end

  mul #(
      .WIDTH                 (8),
      .CPA_ALGORITHM         (2),
      .PIPE_STAGE_AFTER_BOOTH(`MUL_PIPE_STAGE_AFTER_BOOTH),
      .PIPE_STAGE_CSA_LR1    (`MUL_PIPE_STAGE_CSA_LR1),
      .PIPE_STAGE_CSA_LR2    (`MUL_PIPE_STAGE_CSA_LR2),
      .PIPE_STAGE_CSA_LR3    (`MUL_PIPE_STAGE_CSA_LR3),
      .PIPE_STAGE_CSA_LR4    (`MUL_PIPE_STAGE_CSA_LR4),
      .PIPE_STAGES_CPA       (`MUL_PIPE_STAGES_CPA)
  ) u_mul (
      .clk   (clk),
      .a     (a_q),
      .b     (b_q),
      .a_sign(1'b1),
      .b_sign(1'b1),
      .lower (booth_lower),
      .upper (booth_upper)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      acc_s <= '0;
    end else if (clear_d[SB_LAT-1]) begin
      acc_s <= {{16{prod[15]}}, prod};
    end else if (en_d[SB_LAT-1]) begin
      acc_s <= acc_s + {{16{prod[15]}}, prod};
    end
  end

endmodule
