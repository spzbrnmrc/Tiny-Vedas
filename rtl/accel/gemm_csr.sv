///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// AXI-lite GEMM CSR block. Writes accepted in one cycle (always ready).

`timescale 1ns / 1ps

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module gemm_csr (
    input logic clk,
    input logic rstn,

    input  logic [AXI_ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic                      s_axil_awvalid,
    output logic                      s_axil_awready,
    input  logic [AXI_DATA_WIDTH-1:0] s_axil_wdata,
    input  logic [AXI_STRB_WIDTH-1:0] s_axil_wstrb,
    input  logic                      s_axil_wvalid,
    output logic                      s_axil_wready,
    output logic [AXI_RESP_WIDTH-1:0] s_axil_bresp,
    output logic                      s_axil_bvalid,
    input  logic                      s_axil_bready,
    input  logic [AXI_ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic                      s_axil_arvalid,
    output logic                      s_axil_arready,
    output logic [AXI_DATA_WIDTH-1:0] s_axil_rdata,
    output logic [AXI_RESP_WIDTH-1:0] s_axil_rresp,
    output logic                      s_axil_rvalid,
    input  logic                      s_axil_rready,

    output logic [31:0] csr_base_a,
    output logic [31:0] csr_base_b,
    output logic [31:0] csr_base_c,
    output logic [31:0] csr_m,
    output logic [31:0] csr_n,
    output logic [31:0] csr_k,
    output logic        start_pulse,
    output logic        soft_reset,
    input  logic        hw_busy,
    input  logic        hw_done,
    input  logic        hw_done_clr
);

  logic [31:0] base_a, base_b, base_c, m, n, k;
  logic        busy_q, done_q;
  logic        wr_fire, rd_fire;
  logic [ 7:0] wr_off, rd_off;
  logic [31:0] wdata_m;

  /* Accept a new write when idle, or when B for the previous write completes
     this cycle. CPU MMIO is a 1-cycle store pulse and does not retry, so
     back-to-back SW must not be dropped while BVALID is still high. */
  assign wr_fire = s_axil_awvalid & s_axil_wvalid & (~s_axil_bvalid | s_axil_bready);
  assign rd_fire = s_axil_arvalid & ~s_axil_rvalid;

  assign s_axil_awready = s_axil_wvalid & (~s_axil_bvalid | s_axil_bready);
  assign s_axil_wready  = s_axil_awvalid & (~s_axil_bvalid | s_axil_bready);
  assign s_axil_arready = rd_fire;
  assign s_axil_bresp   = AXI_RESP_OKAY;
  assign s_axil_rresp   = AXI_RESP_OKAY;

  assign wr_off = s_axil_awaddr[7:0];
  assign rd_off = s_axil_araddr[7:0];

  assign wdata_m = {
    s_axil_wstrb[3] ? s_axil_wdata[31:24] : 8'h00,
    s_axil_wstrb[2] ? s_axil_wdata[23:16] : 8'h00,
    s_axil_wstrb[1] ? s_axil_wdata[15:8]  : 8'h00,
    s_axil_wstrb[0] ? s_axil_wdata[7:0]   : 8'h00
  };

  assign start_pulse = wr_fire && (wr_off == GEMM_OFF_CTRL[7:0]) &&
                       s_axil_wstrb[0] && s_axil_wdata[GEMM_CTRL_START_BIT] && !hw_busy;
  assign soft_reset  = wr_fire && (wr_off == GEMM_OFF_CTRL[7:0]) &&
                       s_axil_wstrb[0] && s_axil_wdata[GEMM_CTRL_RESET_BIT];

  assign csr_base_a = base_a;
  assign csr_base_b = base_b;
  assign csr_base_c = base_c;
  assign csr_m      = m;
  assign csr_n      = n;
  assign csr_k      = k;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      base_a        <= '0;
      base_b        <= '0;
      base_c        <= '0;
      m             <= '0;
      n             <= '0;
      k             <= '0;
      busy_q        <= 1'b0;
      done_q        <= 1'b0;
      s_axil_bvalid <= 1'b0;
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
    end else begin
      busy_q <= hw_busy;
      if (hw_done) done_q <= 1'b1;
      if (hw_done_clr || soft_reset) done_q <= 1'b0;
      if (start_pulse) done_q <= 1'b0;

      if (wr_fire) begin
        unique case (wr_off)
          GEMM_OFF_BASE_A[7:0]: base_a <= s_axil_wdata;
          GEMM_OFF_BASE_B[7:0]: base_b <= s_axil_wdata;
          GEMM_OFF_BASE_C[7:0]: base_c <= s_axil_wdata;
          GEMM_OFF_M[7:0]:      m      <= s_axil_wdata;
          GEMM_OFF_N[7:0]:      n      <= s_axil_wdata;
          GEMM_OFF_K[7:0]:      k      <= s_axil_wdata;
          default: ;
        endcase
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end

      if (rd_fire) begin
        s_axil_rvalid <= 1'b1;
        unique case (rd_off)
          GEMM_OFF_BASE_A[7:0]: s_axil_rdata <= base_a;
          GEMM_OFF_BASE_B[7:0]: s_axil_rdata <= base_b;
          GEMM_OFF_BASE_C[7:0]: s_axil_rdata <= base_c;
          GEMM_OFF_M[7:0]:      s_axil_rdata <= m;
          GEMM_OFF_N[7:0]:      s_axil_rdata <= n;
          GEMM_OFF_K[7:0]:      s_axil_rdata <= k;
          GEMM_OFF_CTRL[7:0]:   s_axil_rdata <= '0;
          GEMM_OFF_STATUS[7:0]:
          s_axil_rdata <= {30'd0, done_q, busy_q | hw_busy};
          default:              s_axil_rdata <= 32'hDEAD_BEEF;
        endcase
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

  logic unused;
  assign unused = &{1'b0, wdata_m};

endmodule
