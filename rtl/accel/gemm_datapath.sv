///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// 8x8 output-stationary PE array. One K-index per cycle.
// PE drain matches SVLib mul pipe (see GEMM_PE_DRAIN). Padding: zeros in unused A/B lanes.

`timescale 1ns / 1ps

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module gemm_datapath (
    input logic clk,
    input logic rstn,

    input  logic        start,
    input  logic        clear_acc,
    input  logic [ 5:0] k_len,
    input  logic [ 7:0] a_tile[GEMM_PE_DIM][GEMM_K_TILE],
    input  logic [ 7:0] b_tile[GEMM_K_TILE][GEMM_PE_DIM],
    output logic [31:0] c_tile[GEMM_PE_DIM][GEMM_PE_DIM],
    output logic        busy,
    output logic        done,
    output logic        pe_valid
);

  localparam int DRAIN = GEMM_PE_DRAIN;

  typedef enum logic [1:0] {
    S_IDLE  = 2'd0,
    S_RUN   = 2'd1,
    S_DRAIN = 2'd2
  } st_e;

  st_e         st;
  logic [ 5:0] k_idx;
  logic [ 2:0] drain_idx;
  logic [ 5:0] k_len_q;
  logic        clear_q;
  logic        step;
  logic        clear_step;

  assign busy     = (st != S_IDLE);
  assign pe_valid = step;
  assign step       = (st == S_RUN);
  assign clear_step = (st == S_RUN) && (k_idx == 6'd0) && clear_q;

  genvar gi, gj;
  generate
    for (gi = 0; gi < GEMM_PE_DIM; gi++) begin : g_row
      for (gj = 0; gj < GEMM_PE_DIM; gj++) begin : g_col
        gemm_pe u_pe (
            .clk  (clk),
            .rstn (rstn),
            .en   (step),
            .clear(clear_step),
            .a    (a_tile[gi][k_idx]),
            .b    (b_tile[k_idx][gj]),
            .acc  (c_tile[gi][gj])
        );
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st        <= S_IDLE;
      k_idx     <= '0;
      drain_idx <= '0;
      k_len_q   <= 6'd1;
      clear_q   <= 1'b0;
      done      <= 1'b0;
    end else begin
      done <= 1'b0;
      unique case (st)
        S_IDLE: begin
          if (start) begin
            k_len_q   <= (k_len == 6'd0) ? 6'd1 : k_len;
            clear_q   <= clear_acc;
            k_idx     <= '0;
            drain_idx <= '0;
            st        <= S_RUN;
          end
        end
        S_RUN: begin
          if (k_idx + 6'd1 >= k_len_q) begin
            k_idx     <= '0;
            drain_idx <= '0;
            st        <= S_DRAIN;
          end else begin
            k_idx <= k_idx + 6'd1;
          end
        end
        S_DRAIN: begin
          if (drain_idx >= DRAIN - 1) begin
            done <= 1'b1;
            st   <= S_IDLE;
          end else begin
            drain_idx <= drain_idx + 3'd1;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
