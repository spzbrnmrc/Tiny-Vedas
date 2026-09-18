///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Dual AXI4-master DMA: port0 = A reads / C writes, port1 = B reads.
// Unused tile lanes are zeroed in the buffers (padding stays out of DCCM).

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

  typedef enum logic [2:0] {
    D_IDLE   = 3'd0,
    D_AB     = 3'd1,
    D_AB_WAIT= 3'd2,
    D_C      = 3'd3,
    D_C_WAIT = 3'd4
  } dst_e;

  dst_e st;

  logic [3:0] a_r, b_c, c_r, c_c;
  logic [5:0] a_c, b_r;
  logic       a_done, b_done, c_done;
  logic       a_ar_pend, b_ar_pend;
  logic       c_aw_pend, c_w_pend;

  logic [31:0] a_byte_addr, b_byte_addr, c_byte_addr;

  assign a_byte_addr = base_a + ((m0 + {28'd0, a_r}) * dim_k) + (k0 + {26'd0, a_c});
  assign b_byte_addr = base_b + ((k0 + {26'd0, b_r}) * dim_n) + (n0 + {28'd0, b_c});
  assign c_byte_addr = base_c + (((m0 + {28'd0, c_r}) * dim_n) + (n0 + {28'd0, c_c})) * 32'd4;

  assign busy = (st != D_IDLE);

  assign m0_axi_arid    = '0;
  assign m0_axi_arlen   = '0;
  assign m0_axi_arsize  = AXI_SIZE_4B;
  assign m0_axi_arburst = AXI_BURST_INCR;
  assign m0_axi_araddr  = {a_byte_addr[31:2], 2'b00};
  assign m0_axi_arvalid = (st == D_AB) && !a_done && !a_ar_pend &&
                          (a_r < m_tile_len) && (a_c < k_tile_len);
  assign m0_axi_rready  = 1'b1;
  assign m0_axi_awid    = '0;
  assign m0_axi_awlen   = '0;
  assign m0_axi_awsize  = AXI_SIZE_4B;
  assign m0_axi_awburst = AXI_BURST_INCR;
  assign m0_axi_awaddr  = c_byte_addr;
  assign m0_axi_awvalid = (st == D_C) && !c_done && !c_aw_pend &&
                          (c_r < m_tile_len) && (c_c < n_tile_len);
  assign m0_axi_wdata   = c_tile[c_r][c_c];
  assign m0_axi_wstrb   = 4'hF;
  assign m0_axi_wlast   = 1'b1;
  assign m0_axi_wvalid  = (st == D_C) && !c_done && !c_w_pend &&
                          (c_r < m_tile_len) && (c_c < n_tile_len);
  assign m0_axi_bready  = 1'b1;

  assign m1_axi_arid    = 4'd1;
  assign m1_axi_arlen   = '0;
  assign m1_axi_arsize  = AXI_SIZE_4B;
  assign m1_axi_arburst = AXI_BURST_INCR;
  assign m1_axi_araddr  = {b_byte_addr[31:2], 2'b00};
  assign m1_axi_arvalid = (st == D_AB) && !b_done && !b_ar_pend &&
                          (b_r < k_tile_len) && (b_c < n_tile_len);
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

  function automatic logic [7:0] extract_byte(input logic [31:0] w, input logic [1:0] lane);
    case (lane)
      2'd0: extract_byte = w[7:0];
      2'd1: extract_byte = w[15:8];
      2'd2: extract_byte = w[23:16];
      default: extract_byte = w[31:24];
    endcase
  endfunction

  integer ir, ic;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st        <= D_IDLE;
      a_r       <= '0;
      a_c       <= '0;
      b_r       <= '0;
      b_c       <= '0;
      c_r       <= '0;
      c_c       <= '0;
      a_done    <= 1'b1;
      b_done    <= 1'b1;
      c_done    <= 1'b1;
      a_ar_pend <= 1'b0;
      b_ar_pend <= 1'b0;
      c_aw_pend <= 1'b0;
      c_w_pend  <= 1'b0;
      done_ab   <= 1'b0;
      done_c    <= 1'b0;
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
            a_r       <= '0;
            a_c       <= '0;
            b_r       <= '0;
            b_c       <= '0;
            a_done    <= 1'b0;
            b_done    <= 1'b0;
            a_ar_pend <= 1'b0;
            b_ar_pend <= 1'b0;
            for (ir = 0; ir < GEMM_PE_DIM; ir++) begin
              for (ic = 0; ic < GEMM_K_TILE; ic++) begin
                a_tile[ir][ic] <= '0;
                b_tile[ic][ir] <= '0;
              end
            end
            st <= D_AB;
          end else if (start_c) begin
            c_r       <= '0;
            c_c       <= '0;
            c_done    <= 1'b0;
            c_aw_pend <= 1'b0;
            c_w_pend  <= 1'b0;
            st        <= D_C;
          end
        end

        D_AB: begin
          if (!a_done && (a_r >= m_tile_len || a_c >= k_tile_len)) begin
            a_done <= 1'b1;
          end
          if (!b_done && (b_r >= k_tile_len || b_c >= n_tile_len)) begin
            b_done <= 1'b1;
          end

          if (m0_axi_arvalid && m0_axi_arready) a_ar_pend <= 1'b1;
          if (m1_axi_arvalid && m1_axi_arready) b_ar_pend <= 1'b1;

          if (m0_axi_rvalid && a_ar_pend) begin
            a_tile[a_r][a_c] <= extract_byte(m0_axi_rdata, a_byte_addr[1:0]);
            a_ar_pend        <= 1'b0;
            if (a_c + 6'd1 >= k_tile_len) begin
              a_c <= '0;
              if (a_r + 4'd1 >= m_tile_len) a_done <= 1'b1;
              else a_r <= a_r + 4'd1;
            end else begin
              a_c <= a_c + 6'd1;
            end
          end

          if (m1_axi_rvalid && b_ar_pend) begin
            b_tile[b_r][b_c] <= extract_byte(m1_axi_rdata, b_byte_addr[1:0]);
            b_ar_pend        <= 1'b0;
            if (b_c + 4'd1 >= n_tile_len) begin
              b_c <= '0;
              if (b_r + 6'd1 >= k_tile_len) b_done <= 1'b1;
              else b_r <= b_r + 6'd1;
            end else begin
              b_c <= b_c + 4'd1;
            end
          end

          if ((a_done || (a_r >= m_tile_len)) && (b_done || (b_r >= k_tile_len)) &&
              !a_ar_pend && !b_ar_pend) begin
            done_ab <= 1'b1;
            st      <= D_IDLE;
          end
        end

        D_C: begin
          if (!c_done && (c_r >= m_tile_len || c_c >= n_tile_len)) begin
            done_c <= 1'b1;
            st     <= D_IDLE;
            c_done <= 1'b1;
          end else begin
            if (m0_axi_awvalid && m0_axi_awready) c_aw_pend <= 1'b1;
            if (m0_axi_wvalid && m0_axi_wready) c_w_pend <= 1'b1;
            if ((c_aw_pend || (m0_axi_awvalid && m0_axi_awready)) &&
                (c_w_pend || (m0_axi_wvalid && m0_axi_wready))) begin
              c_aw_pend <= 1'b0;
              c_w_pend  <= 1'b0;
              if (c_c + 4'd1 >= n_tile_len) begin
                c_c <= '0;
                if (c_r + 4'd1 >= m_tile_len) begin
                  c_done <= 1'b1;
                  done_c <= 1'b1;
                  st     <= D_IDLE;
                end else begin
                  c_r <= c_r + 4'd1;
                end
              end else begin
                c_c <= c_c + 4'd1;
              end
            end
          end
        end

        default: st <= D_IDLE;
      endcase
    end
  end

  logic unused;
  assign unused = &{1'b0, m0_axi_rid, m0_axi_rresp, m0_axi_rlast, m0_axi_bid, m0_axi_bresp,
                    m0_axi_bvalid, m1_axi_rid, m1_axi_rresp, m1_axi_rlast, m1_axi_bid,
                    m1_axi_bresp, m1_axi_bvalid, m1_axi_awready, m1_axi_wready};
endmodule
