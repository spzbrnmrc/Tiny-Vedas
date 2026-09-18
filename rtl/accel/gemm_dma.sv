///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Dual AXI4-master DMA: port0 = A reads / C writes, port1 = B reads.
//
// Packed INCR bursts on the 32-bit DCCM bus:
//   A row = K-contiguous int8  (K-tile 32 → 8 beats when 4-byte aligned)
//   B row = N-contiguous int8  (N-tile 8  → 2 beats when 4-byte aligned)
//   C row = N-contiguous int32 (AWLEN = n_tile-1)
// Cross-row is a new burst. One outstanding burst per port.
//
// AXI addresses come from registered incremental pointers. The only
// m0*K / k0*N math is flopped at start_ab / start_c.

`timescale 1ns / 1ps

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module gemm_dma (
    input logic clk,
    input logic rstn,

    input  logic        start_ab,
    input  logic        start_c,
    input  logic [31:0] base_a,
    input  logic [31:0] base_b,
    input  logic [31:0] base_c,
    input  logic [31:0] dim_m,
    input  logic [31:0] dim_n,
    input  logic [31:0] dim_k,
    input  logic [31:0] m0,
    input  logic [31:0] n0,
    input  logic [31:0] k0,
    input  logic [ 5:0] k_tile_len,
    input  logic [ 3:0] m_tile_len,
    input  logic [ 3:0] n_tile_len,
    output logic [ 7:0] a_tile[GEMM_PE_DIM][GEMM_K_TILE],
    output logic [ 7:0] b_tile[GEMM_K_TILE][GEMM_PE_DIM],
    input  logic [31:0] c_tile[GEMM_PE_DIM][GEMM_PE_DIM],

    output logic busy,
    output logic done_ab,
    output logic done_c,

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

  typedef enum logic [1:0] {
    D_IDLE = 2'd0,
    D_AB   = 2'd1,
    D_C    = 2'd2
  } dst_e;

  dst_e st;

  logic [3:0] a_r, b_c, c_r, c_c;
  logic [5:0] a_c, b_r;
  logic       a_done, b_done, c_done;
  logic       a_ar_pend, b_ar_pend, a_first, b_first;
  logic       c_aw_pend, c_w_row_done;

  logic [31:0] a_row_base, b_row_base, c_row_base;
  logic [31:0] dim_n_q, dim_k_q;
  logic [ 5:0] k_len_q;
  logic [ 3:0] m_len_q, n_len_q;

  function automatic logic [7:0] packed_beats(input logic [1:0] off, input logic [5:0] nbytes);
    packed_beats = ({6'd0, off} + {2'b00, nbytes} + 8'd3) >> 2;
  endfunction

  function automatic logic [5:0] bytes_this_beat(input logic [1:0] skip, input logic [5:0] remain);
    logic [5:0] avail;
    avail = 6'd4 - {4'd0, skip};
    bytes_this_beat = (remain < avail) ? remain : avail;
  endfunction

  function automatic logic [7:0] extract_byte(input logic [31:0] w, input logic [1:0] lane);
    case (lane)
      2'd0: extract_byte = w[7:0];
      2'd1: extract_byte = w[15:8];
      2'd2: extract_byte = w[23:16];
      default: extract_byte = w[31:24];
    endcase
  endfunction

  logic [7:0] a_beats, b_beats;
  logic [5:0] a_take, b_take;
  logic [1:0] a_skip, b_skip;

  assign a_beats = packed_beats(a_row_base[1:0], k_len_q);
  assign b_beats = packed_beats(b_row_base[1:0], {2'b00, n_len_q});
  assign a_skip  = a_first ? a_row_base[1:0] : 2'd0;
  assign b_skip  = b_first ? b_row_base[1:0] : 2'd0;
  assign a_take  = bytes_this_beat(a_skip, k_len_q - a_c);
  assign b_take  = bytes_this_beat(b_skip, {2'b00, n_len_q} - {2'b00, b_c});

  assign busy = (st != D_IDLE);

  assign m0_axi_arid    = '0;
  assign m0_axi_arsize  = AXI_SIZE_4B;
  assign m0_axi_arburst = AXI_BURST_INCR;
  assign m0_axi_araddr  = {a_row_base[31:2], 2'b00};
  assign m0_axi_arlen   = (a_beats == 8'd0) ? 8'd0 : (a_beats - 8'd1);
  assign m0_axi_arvalid = (st == D_AB) && !a_done && !a_ar_pend &&
                          (a_r < m_len_q) && (k_len_q != 6'd0);
  assign m0_axi_rready  = 1'b1;

  assign m0_axi_awid    = '0;
  assign m0_axi_awsize  = AXI_SIZE_4B;
  assign m0_axi_awburst = AXI_BURST_INCR;
  assign m0_axi_awaddr  = c_row_base;
  assign m0_axi_awlen   = (n_len_q == 4'd0) ? 8'd0 : ({4'd0, n_len_q} - 8'd1);
  assign m0_axi_awvalid = (st == D_C) && !c_done && !c_aw_pend && !c_w_row_done &&
                          (c_r < m_len_q) && (n_len_q != 4'd0);
  assign m0_axi_wdata   = c_tile[c_r][c_c];
  assign m0_axi_wstrb   = 4'hF;
  assign m0_axi_wlast   = (c_c + 4'd1 >= n_len_q);
  assign m0_axi_wvalid  = (st == D_C) && !c_done && !c_w_row_done &&
                          (c_r < m_len_q) && (n_len_q != 4'd0) &&
                          (c_aw_pend || m0_axi_awvalid);
  assign m0_axi_bready  = 1'b1;

  assign m1_axi_arid    = 4'd1;
  assign m1_axi_arsize  = AXI_SIZE_4B;
  assign m1_axi_arburst = AXI_BURST_INCR;
  assign m1_axi_araddr  = {b_row_base[31:2], 2'b00};
  assign m1_axi_arlen   = (b_beats == 8'd0) ? 8'd0 : (b_beats - 8'd1);
  assign m1_axi_arvalid = (st == D_AB) && !b_done && !b_ar_pend &&
                          (b_r < k_len_q) && (n_len_q != 4'd0);
  assign m1_axi_rready  = 1'b1;
  assign m1_axi_awid    = '0;
  assign m1_axi_awaddr  = '0;
  assign m1_axi_awlen   = '0;
  assign m1_axi_awsize  = AXI_SIZE_4B;
  assign m1_axi_awburst = AXI_BURST_INCR;
  assign m1_axi_awvalid = 1'b0;
  assign m1_axi_wdata   = '0;
  assign m1_axi_wstrb   = '0;
  assign m1_axi_wlast   = 1'b1;
  assign m1_axi_wvalid  = 1'b0;
  assign m1_axi_bready  = 1'b1;

  integer ir, ic;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st           <= D_IDLE;
      a_r          <= '0;
      a_c          <= '0;
      b_r          <= '0;
      b_c          <= '0;
      c_r          <= '0;
      c_c          <= '0;
      a_done       <= 1'b1;
      b_done       <= 1'b1;
      c_done       <= 1'b1;
      a_ar_pend    <= 1'b0;
      b_ar_pend    <= 1'b0;
      a_first      <= 1'b1;
      b_first      <= 1'b1;
      c_aw_pend    <= 1'b0;
      c_w_row_done <= 1'b0;
      a_row_base   <= '0;
      b_row_base   <= '0;
      c_row_base   <= '0;
      dim_n_q      <= '0;
      dim_k_q      <= '0;
      k_len_q      <= '0;
      m_len_q      <= '0;
      n_len_q      <= '0;
      done_ab      <= 1'b0;
      done_c       <= 1'b0;
      for (ir = 0; ir < GEMM_PE_DIM; ir++) begin
        for (ic = 0; ic < GEMM_K_TILE; ic++) begin
          a_tile[ir][ic] <= '0;
          b_tile[ic][ir] <= '0;
        end
      end
    end else begin
      done_ab <= 1'b0;
      done_c  <= 1'b0;

      unique case (st)
        D_IDLE: begin
          if (start_ab) begin
            a_r        <= '0;
            a_c        <= '0;
            b_r        <= '0;
            b_c        <= '0;
            a_done     <= (m_tile_len == 4'd0) || (k_tile_len == 6'd0);
            b_done     <= (k_tile_len == 6'd0) || (n_tile_len == 4'd0);
            a_ar_pend  <= 1'b0;
            b_ar_pend  <= 1'b0;
            a_first    <= 1'b1;
            b_first    <= 1'b1;
            a_row_base <= base_a + (m0 * dim_k) + k0;
            b_row_base <= base_b + (k0 * dim_n) + n0;
            dim_n_q    <= dim_n;
            dim_k_q    <= dim_k;
            k_len_q    <= k_tile_len;
            m_len_q    <= m_tile_len;
            n_len_q    <= n_tile_len;
            for (ir = 0; ir < GEMM_PE_DIM; ir++) begin
              for (ic = 0; ic < GEMM_K_TILE; ic++) begin
                a_tile[ir][ic] <= '0;
                b_tile[ic][ir] <= '0;
              end
            end
            st <= D_AB;
          end else if (start_c) begin
            c_r          <= '0;
            c_c          <= '0;
            c_done       <= (m_tile_len == 4'd0) || (n_tile_len == 4'd0);
            c_aw_pend    <= 1'b0;
            c_w_row_done <= 1'b0;
            c_row_base   <= base_c + ((m0 * dim_n + n0) << 2);
            dim_n_q      <= dim_n;
            m_len_q      <= m_tile_len;
            n_len_q      <= n_tile_len;
            st           <= D_C;
          end
        end

        D_AB: begin
          if (m0_axi_arvalid && m0_axi_arready) a_ar_pend <= 1'b1;
          if (m1_axi_arvalid && m1_axi_arready) b_ar_pend <= 1'b1;

          if (m0_axi_rvalid && a_ar_pend) begin
            for (int bi = 0; bi < 4; bi++) begin
              if ((bi[1:0] >= a_skip) && ({4'd0, (bi[1:0] - a_skip)} < a_take)) begin
                a_tile[a_r][a_c + {4'd0, (bi[1:0] - a_skip)}] <=
                    extract_byte(m0_axi_rdata, bi[1:0]);
              end
            end
            a_first <= 1'b0;
            if (m0_axi_rlast) begin
              a_ar_pend  <= 1'b0;
              a_c        <= '0;
              a_first    <= 1'b1;
              a_row_base <= a_row_base + dim_k_q;
              if (a_r + 4'd1 >= m_len_q) a_done <= 1'b1;
              else a_r <= a_r + 4'd1;
            end else begin
              a_c <= a_c + a_take;
            end
          end

          if (m1_axi_rvalid && b_ar_pend) begin
            for (int bj = 0; bj < 4; bj++) begin
              if ((bj[1:0] >= b_skip) && ({4'd0, (bj[1:0] - b_skip)} < b_take)) begin
                b_tile[b_r][b_c + (bj[1:0] - b_skip)] <=
                    extract_byte(m1_axi_rdata, bj[1:0]);
              end
            end
            b_first <= 1'b0;
            if (m1_axi_rlast) begin
              b_ar_pend  <= 1'b0;
              b_c        <= '0;
              b_first    <= 1'b1;
              b_row_base <= b_row_base + dim_n_q;
              if (b_r + 6'd1 >= k_len_q) b_done <= 1'b1;
              else b_r <= b_r + 6'd1;
            end else begin
              b_c <= b_c + b_take[3:0];
            end
          end

          if (a_done && b_done && !a_ar_pend && !b_ar_pend) begin
            done_ab <= 1'b1;
            st      <= D_IDLE;
          end
        end

        D_C: begin
          if (c_done) begin
            done_c <= 1'b1;
            st     <= D_IDLE;
          end else begin
            if (m0_axi_awvalid && m0_axi_awready) c_aw_pend <= 1'b1;

            if (m0_axi_wvalid && m0_axi_wready) begin
              if (m0_axi_wlast) c_w_row_done <= 1'b1;
              else c_c <= c_c + 4'd1;
            end

            if (m0_axi_bvalid && m0_axi_bready) begin
              c_aw_pend    <= 1'b0;
              c_w_row_done <= 1'b0;
              c_c          <= '0;
              c_row_base   <= c_row_base + {dim_n_q[29:0], 2'b00};
              if (c_r + 4'd1 >= m_len_q) begin
                c_done <= 1'b1;
                done_c <= 1'b1;
                st     <= D_IDLE;
              end else begin
                c_r <= c_r + 4'd1;
              end
            end
          end
        end

        default: st <= D_IDLE;
      endcase
    end
  end

  logic unused;
  assign unused = &{1'b0, dim_m, m0_axi_rid, m0_axi_rresp, m0_axi_bid, m0_axi_bresp,
                    m1_axi_rid, m1_axi_rresp, m1_axi_bid, m1_axi_bresp, m1_axi_bvalid,
                    m1_axi_awready, m1_axi_wready};
endmodule
