///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Stable GEMM interface: CSR + DMA + tile scheduler + swappable datapath.

`timescale 1ns / 1ps

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module gemm_top (
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

    output logic                        accel_hold,
    output logic                        gemm_busy,
    output logic                        pe_valid,
    output logic                        dma_arvalid,
    output logic                        dma_awvalid,
    output logic                        status_done,

    output logic [   AXI_ID_WIDTH-1:0] m0_axi_arid,
    output logic [ AXI_ADDR_WIDTH-1:0] m0_axi_araddr,
    output logic [   AXI_LEN_WIDTH-1:0] m0_axi_arlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m0_axi_arsize,
    output logic [ AXI_BURST_WIDTH-1:0] m0_axi_arburst,
    output logic                        m0_axi_arvalid,
    input  logic                        m0_axi_arready,
    input  logic [   AXI_ID_WIDTH-1:0] m0_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0]  m0_axi_rdata,
    input  logic [ AXI_RESP_WIDTH-1:0] m0_axi_rresp,
    input  logic                        m0_axi_rlast,
    input  logic                        m0_axi_rvalid,
    output logic                        m0_axi_rready,
    output logic [   AXI_ID_WIDTH-1:0] m0_axi_awid,
    output logic [ AXI_ADDR_WIDTH-1:0] m0_axi_awaddr,
    output logic [   AXI_LEN_WIDTH-1:0] m0_axi_awlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m0_axi_awsize,
    output logic [ AXI_BURST_WIDTH-1:0] m0_axi_awburst,
    output logic                        m0_axi_awvalid,
    input  logic                        m0_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0]  m0_axi_wdata,
    output logic [AXI_STRB_WIDTH-1:0]  m0_axi_wstrb,
    output logic                        m0_axi_wlast,
    output logic                        m0_axi_wvalid,
    input  logic                        m0_axi_wready,
    input  logic [   AXI_ID_WIDTH-1:0] m0_axi_bid,
    input  logic [ AXI_RESP_WIDTH-1:0] m0_axi_bresp,
    input  logic                        m0_axi_bvalid,
    output logic                        m0_axi_bready,

    output logic [   AXI_ID_WIDTH-1:0] m1_axi_arid,
    output logic [ AXI_ADDR_WIDTH-1:0] m1_axi_araddr,
    output logic [   AXI_LEN_WIDTH-1:0] m1_axi_arlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m1_axi_arsize,
    output logic [ AXI_BURST_WIDTH-1:0] m1_axi_arburst,
    output logic                        m1_axi_arvalid,
    input  logic                        m1_axi_arready,
    input  logic [   AXI_ID_WIDTH-1:0] m1_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0]  m1_axi_rdata,
    input  logic [ AXI_RESP_WIDTH-1:0] m1_axi_rresp,
    input  logic                        m1_axi_rlast,
    input  logic                        m1_axi_rvalid,
    output logic                        m1_axi_rready,
    output logic [   AXI_ID_WIDTH-1:0] m1_axi_awid,
    output logic [ AXI_ADDR_WIDTH-1:0] m1_axi_awaddr,
    output logic [   AXI_LEN_WIDTH-1:0] m1_axi_awlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m1_axi_awsize,
    output logic [ AXI_BURST_WIDTH-1:0] m1_axi_awburst,
    output logic                        m1_axi_awvalid,
    input  logic                        m1_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0]  m1_axi_wdata,
    output logic [AXI_STRB_WIDTH-1:0]  m1_axi_wstrb,
    output logic                        m1_axi_wlast,
    output logic                        m1_axi_wvalid,
    input  logic                        m1_axi_wready,
    input  logic [   AXI_ID_WIDTH-1:0] m1_axi_bid,
    input  logic [ AXI_RESP_WIDTH-1:0] m1_axi_bresp,
    input  logic                        m1_axi_bvalid,
    output logic                        m1_axi_bready
);

  logic [31:0] csr_base_a, csr_base_b, csr_base_c, csr_m, csr_n, csr_k;
  logic        start_pulse, soft_reset;
  logic        hw_busy, hw_done, hw_done_clr;

  typedef enum logic [2:0] {
    G_IDLE    = 3'd0,
    G_FILL    = 3'd1,
    G_ARM     = 3'd2,
    G_COMPUTE = 3'd3,
    G_STORE   = 3'd4,
    G_NEXT    = 3'd5,
    G_DONE    = 3'd6
  } gst_e;

  gst_e st;

  logic [31:0] m0, n0, k0;
  logic [ 3:0] m_tile, n_tile;
  logic [ 5:0] k_tile;
  logic        clear_acc;
  logic        ping;
  logic        dp_start, dma_start_ab, dma_start_c;
  logic        dp_busy, dp_done, dma_busy, dma_done_ab, dma_done_c;
  logic        job_busy;

  logic [ 7:0] a_buf[2][GEMM_PE_DIM][GEMM_K_TILE];
  logic [ 7:0] b_buf[2][GEMM_K_TILE][GEMM_PE_DIM];
  logic [31:0] c_buf[GEMM_PE_DIM][GEMM_PE_DIM];
  logic [ 7:0] a_fill[GEMM_PE_DIM][GEMM_K_TILE];
  logic [ 7:0] b_fill[GEMM_K_TILE][GEMM_PE_DIM];
  logic [ 7:0] a_comp[GEMM_PE_DIM][GEMM_K_TILE];
  logic [ 7:0] b_comp[GEMM_K_TILE][GEMM_PE_DIM];

  integer ii, jj, kk;

  function automatic logic [31:0] tile_rem(input logic [31:0] total, input logic [31:0] orig,
                                           input logic [31:0] maxv);
    logic [31:0] remaining;
    remaining = (orig >= total) ? 32'd0 : (total - orig);
    tile_rem = (remaining > maxv) ? maxv : remaining;
  endfunction

  always_comb begin
    for (int ci = 0; ci < GEMM_PE_DIM; ci++) begin
      for (int ck = 0; ck < GEMM_K_TILE; ck++) begin
        a_comp[ci][ck] = a_buf[ping][ci][ck];
      end
    end
    for (int ck = 0; ck < GEMM_K_TILE; ck++) begin
      for (int cj = 0; cj < GEMM_PE_DIM; cj++) begin
        b_comp[ck][cj] = b_buf[ping][ck][cj];
      end
    end
  end

  gemm_csr u_csr (
      .clk          (clk),
      .rstn         (rstn),
      .s_axil_awaddr(s_axil_awaddr),
      .s_axil_awvalid(s_axil_awvalid),
      .s_axil_awready(s_axil_awready),
      .s_axil_wdata (s_axil_wdata),
      .s_axil_wstrb (s_axil_wstrb),
      .s_axil_wvalid(s_axil_wvalid),
      .s_axil_wready(s_axil_wready),
      .s_axil_bresp (s_axil_bresp),
      .s_axil_bvalid(s_axil_bvalid),
      .s_axil_bready(s_axil_bready),
      .s_axil_araddr(s_axil_araddr),
      .s_axil_arvalid(s_axil_arvalid),
      .s_axil_arready(s_axil_arready),
      .s_axil_rdata (s_axil_rdata),
      .s_axil_rresp (s_axil_rresp),
      .s_axil_rvalid(s_axil_rvalid),
      .s_axil_rready(s_axil_rready),
      .csr_base_a   (csr_base_a),
      .csr_base_b   (csr_base_b),
      .csr_base_c   (csr_base_c),
      .csr_m        (csr_m),
      .csr_n        (csr_n),
      .csr_k        (csr_k),
      .start_pulse  (start_pulse),
      .soft_reset   (soft_reset),
      .hw_busy      (job_busy),
      .hw_done      (hw_done),
      .hw_done_clr  (hw_done_clr)
  );

  gemm_dma u_dma (
      .clk        (clk),
      .rstn       (rstn),
      .start_ab   (dma_start_ab),
      .start_c    (dma_start_c),
      .base_a     (csr_base_a),
      .base_b     (csr_base_b),
      .base_c     (csr_base_c),
      .dim_m      (csr_m),
      .dim_n      (csr_n),
      .dim_k      (csr_k),
      .m0         (m0),
      .n0         (n0),
      .k0         (k0),
      .k_tile_len (k_tile),
      .m_tile_len (m_tile),
      .n_tile_len (n_tile),
      .a_tile     (a_fill),
      .b_tile     (b_fill),
      .c_tile     (c_buf),
      .busy       (dma_busy),
      .done_ab    (dma_done_ab),
      .done_c     (dma_done_c),
      .m0_axi_arid(m0_axi_arid),
      .m0_axi_araddr(m0_axi_araddr),
      .m0_axi_arlen(m0_axi_arlen),
      .m0_axi_arsize(m0_axi_arsize),
      .m0_axi_arburst(m0_axi_arburst),
      .m0_axi_arvalid(m0_axi_arvalid),
      .m0_axi_arready(m0_axi_arready),
      .m0_axi_rid(m0_axi_rid),
      .m0_axi_rdata(m0_axi_rdata),
      .m0_axi_rresp(m0_axi_rresp),
      .m0_axi_rlast(m0_axi_rlast),
      .m0_axi_rvalid(m0_axi_rvalid),
      .m0_axi_rready(m0_axi_rready),
      .m0_axi_awid(m0_axi_awid),
      .m0_axi_awaddr(m0_axi_awaddr),
      .m0_axi_awlen(m0_axi_awlen),
      .m0_axi_awsize(m0_axi_awsize),
      .m0_axi_awburst(m0_axi_awburst),
      .m0_axi_awvalid(m0_axi_awvalid),
      .m0_axi_awready(m0_axi_awready),
      .m0_axi_wdata(m0_axi_wdata),
      .m0_axi_wstrb(m0_axi_wstrb),
      .m0_axi_wlast(m0_axi_wlast),
      .m0_axi_wvalid(m0_axi_wvalid),
      .m0_axi_wready(m0_axi_wready),
      .m0_axi_bid(m0_axi_bid),
      .m0_axi_bresp(m0_axi_bresp),
      .m0_axi_bvalid(m0_axi_bvalid),
      .m0_axi_bready(m0_axi_bready),
      .m1_axi_arid(m1_axi_arid),
      .m1_axi_araddr(m1_axi_araddr),
      .m1_axi_arlen(m1_axi_arlen),
      .m1_axi_arsize(m1_axi_arsize),
      .m1_axi_arburst(m1_axi_arburst),
      .m1_axi_arvalid(m1_axi_arvalid),
      .m1_axi_arready(m1_axi_arready),
      .m1_axi_rid(m1_axi_rid),
      .m1_axi_rdata(m1_axi_rdata),
      .m1_axi_rresp(m1_axi_rresp),
      .m1_axi_rlast(m1_axi_rlast),
      .m1_axi_rvalid(m1_axi_rvalid),
      .m1_axi_rready(m1_axi_rready),
      .m1_axi_awid(m1_axi_awid),
      .m1_axi_awaddr(m1_axi_awaddr),
      .m1_axi_awlen(m1_axi_awlen),
      .m1_axi_awsize(m1_axi_awsize),
      .m1_axi_awburst(m1_axi_awburst),
      .m1_axi_awvalid(m1_axi_awvalid),
      .m1_axi_awready(m1_axi_awready),
      .m1_axi_wdata(m1_axi_wdata),
      .m1_axi_wstrb(m1_axi_wstrb),
      .m1_axi_wlast(m1_axi_wlast),
      .m1_axi_wvalid(m1_axi_wvalid),
      .m1_axi_wready(m1_axi_wready),
      .m1_axi_bid(m1_axi_bid),
      .m1_axi_bresp(m1_axi_bresp),
      .m1_axi_bvalid(m1_axi_bvalid),
      .m1_axi_bready(m1_axi_bready)
  );

  gemm_datapath u_dp (
      .clk      (clk),
      .rstn     (rstn),
      .start    (dp_start),
      .clear_acc(clear_acc),
      .k_len    (k_tile),
      .a_tile   (a_comp),
      .b_tile   (b_comp),
      .c_tile   (c_buf),
      .busy     (dp_busy),
      .done     (dp_done),
      .pe_valid (pe_valid)
  );

  assign job_busy    = (st != G_IDLE);
  assign gemm_busy   = start_pulse | job_busy;
  assign accel_hold  = start_pulse | job_busy;
  assign dma_arvalid = m0_axi_arvalid | m1_axi_arvalid;
  assign dma_awvalid = m0_axi_awvalid;
  assign status_done = (st == G_DONE);
  assign hw_done_clr = start_pulse | soft_reset;

  always_ff @(posedge clk) begin
    if (!rstn || soft_reset) begin
      st         <= G_IDLE;
      m0         <= '0;
      n0         <= '0;
      k0         <= '0;
      m_tile     <= '0;
      n_tile     <= '0;
      k_tile     <= '0;
      clear_acc  <= 1'b1;
      ping       <= 1'b0;
      dp_start   <= 1'b0;
      dma_start_ab <= 1'b0;
      dma_start_c  <= 1'b0;
      hw_done    <= 1'b0;
      for (ii = 0; ii < 2; ii++) begin
        for (jj = 0; jj < GEMM_PE_DIM; jj++) begin
          for (kk = 0; kk < GEMM_K_TILE; kk++) begin
            a_buf[ii][jj][kk] <= '0;
            b_buf[ii][kk][jj] <= '0;
          end
        end
      end
    end else begin
      dp_start     <= 1'b0;
      dma_start_ab <= 1'b0;
      dma_start_c  <= 1'b0;
      hw_done      <= 1'b0;

      unique case (st)
        G_IDLE: begin
          if (start_pulse && csr_m != 0 && csr_n != 0 && csr_k != 0) begin
            m0        <= '0;
            n0        <= '0;
            k0        <= '0;
            m_tile    <= 4'(tile_rem(csr_m, 32'd0, GEMM_PE_DIM));
            n_tile    <= 4'(tile_rem(csr_n, 32'd0, GEMM_PE_DIM));
            k_tile    <= 6'(tile_rem(csr_k, 32'd0, GEMM_K_TILE));
            clear_acc <= 1'b1;
            ping      <= 1'b0;
            dma_start_ab <= 1'b1;
            st        <= G_FILL;
          end else if (start_pulse) begin
            hw_done <= 1'b1;
            st      <= G_DONE;
          end
        end

        G_FILL: begin
          if (dma_done_ab) begin
            for (ii = 0; ii < GEMM_PE_DIM; ii++) begin
              for (kk = 0; kk < GEMM_K_TILE; kk++) begin
                a_buf[ping][ii][kk] <= a_fill[ii][kk];
                b_buf[ping][kk][ii] <= b_fill[kk][ii];
              end
            end
            st <= G_ARM;
          end
        end

        G_ARM: begin
          dp_start <= 1'b1;
          st       <= G_COMPUTE;
        end

        G_COMPUTE: begin
          if (dp_done) begin
            if (k0 + {26'd0, k_tile} < csr_k) begin
              k0        <= k0 + {26'd0, k_tile};
              k_tile    <= 6'(tile_rem(csr_k, k0 + {26'd0, k_tile}, GEMM_K_TILE));
              clear_acc <= 1'b0;
              ping      <= ~ping;
              dma_start_ab <= 1'b1;
              st        <= G_FILL;
            end else begin
              dma_start_c <= 1'b1;
              st          <= G_STORE;
            end
          end
        end

        G_STORE: begin
          if (dma_done_c) begin
            st <= G_NEXT;
          end
        end

        G_NEXT: begin
          if (n0 + {28'd0, n_tile} < csr_n) begin
            n0        <= n0 + {28'd0, n_tile};
            k0        <= '0;
            n_tile    <= 4'(tile_rem(csr_n, n0 + {28'd0, n_tile}, GEMM_PE_DIM));
            k_tile    <= 6'(tile_rem(csr_k, 32'd0, GEMM_K_TILE));
            clear_acc <= 1'b1;
            ping      <= 1'b0;
            dma_start_ab <= 1'b1;
            st        <= G_FILL;
          end else if (m0 + {28'd0, m_tile} < csr_m) begin
            m0        <= m0 + {28'd0, m_tile};
            n0        <= '0;
            k0        <= '0;
            m_tile    <= 4'(tile_rem(csr_m, m0 + {28'd0, m_tile}, GEMM_PE_DIM));
            n_tile    <= 4'(tile_rem(csr_n, 32'd0, GEMM_PE_DIM));
            k_tile    <= 6'(tile_rem(csr_k, 32'd0, GEMM_K_TILE));
            clear_acc <= 1'b1;
            ping      <= 1'b0;
            dma_start_ab <= 1'b1;
            st        <= G_FILL;
          end else begin
            hw_done <= 1'b1;
            st      <= G_DONE;
          end
        end

        G_DONE: begin
          st <= G_IDLE;
        end

        default: st <= G_IDLE;
      endcase
    end
  end

  logic unused;
  assign unused = &{1'b0, dma_busy, dp_busy};

endmodule
