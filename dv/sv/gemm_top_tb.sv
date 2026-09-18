///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Standalone gemm_top testbench with AXI DCCM model.

`timescale 1ns / 1ps

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module gemm_top_tb;

  localparam int MEM_WORDS = 262144;

  logic clk = 0;
  logic rstn;
  always #5 clk = ~clk;

  int M, N, K, SEED, NSEED;
  int cycles;
  int errors;
  int unsigned t0;

  logic [AXI_ADDR_WIDTH-1:0] awaddr;
  logic                      awvalid, awready;
  logic [AXI_DATA_WIDTH-1:0] wdata;
  logic [AXI_STRB_WIDTH-1:0] wstrb;
  logic                      wvalid, wready;
  logic [AXI_RESP_WIDTH-1:0] bresp;
  logic                      bvalid, bready;
  logic [AXI_ADDR_WIDTH-1:0] araddr;
  logic                      arvalid, arready;
  logic [AXI_DATA_WIDTH-1:0] rdata;
  logic [AXI_RESP_WIDTH-1:0] rresp;
  logic                      rvalid, rready;

  logic hold, busy, pe_valid, dma_arvalid, dma_awvalid, status_done;

  logic [   AXI_ID_WIDTH-1:0] m0_arid, m1_arid;
  logic [ AXI_ADDR_WIDTH-1:0] m0_araddr, m1_araddr;
  logic [   AXI_LEN_WIDTH-1:0] m0_arlen, m1_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] m0_arsize, m1_arsize;
  logic [ AXI_BURST_WIDTH-1:0] m0_arburst, m1_arburst;
  logic                        m0_arvalid, m1_arvalid, m0_arready, m1_arready;
  logic [   AXI_ID_WIDTH-1:0] m0_rid, m1_rid;
  logic [AXI_DATA_WIDTH-1:0]  m0_rdata, m1_rdata;
  logic [ AXI_RESP_WIDTH-1:0] m0_rresp, m1_rresp;
  logic                        m0_rlast, m1_rlast, m0_rvalid, m1_rvalid, m0_rready, m1_rready;
  logic [   AXI_ID_WIDTH-1:0] m0_awid, m1_awid;
  logic [ AXI_ADDR_WIDTH-1:0] m0_awaddr, m1_awaddr;
  logic [   AXI_LEN_WIDTH-1:0] m0_awlen, m1_awlen;
  logic [  AXI_SIZE_WIDTH-1:0] m0_awsize, m1_awsize;
  logic [ AXI_BURST_WIDTH-1:0] m0_awburst, m1_awburst;
  logic                        m0_awvalid, m1_awvalid, m0_awready, m1_awready;
  logic [AXI_DATA_WIDTH-1:0]  m0_wdata, m1_wdata;
  logic [AXI_STRB_WIDTH-1:0]  m0_wstrb, m1_wstrb;
  logic                        m0_wlast, m1_wlast, m0_wvalid, m1_wvalid, m0_wready, m1_wready;
  logic [   AXI_ID_WIDTH-1:0] m0_bid, m1_bid;
  logic [ AXI_RESP_WIDTH-1:0] m0_bresp, m1_bresp;
  logic                        m0_bvalid, m1_bvalid, m0_bready, m1_bready;

  logic [31:0] mem[MEM_WORDS];

  localparam logic [31:0] BASE_A = 32'h0010_0000;
  localparam logic [31:0] BASE_B = 32'h0014_0000;
  localparam logic [31:0] BASE_C = 32'h0018_0000;

  function automatic int signed s8(input logic [7:0] b);
    s8 = signed'(b);
  endfunction

  function automatic int unsigned word_addr(input logic [31:0] byte_addr);
    word_addr = (byte_addr >> 2) % MEM_WORDS;
  endfunction

  /* AXI4 INCR slave (SIZE=4B), one outstanding burst per port. */
  logic        m0_rd_act, m1_rd_act, m0_wr_act;
  logic [31:0] m0_rd_addr, m1_rd_addr, m0_wr_addr, m0_waddr_now;
  logic [7:0]  m0_rd_len, m1_rd_len, m0_rd_beat, m1_rd_beat;

  assign m0_waddr_now = m0_wr_act ? m0_wr_addr : m0_awaddr;

  assign m0_arready = rstn && !m0_rd_act;
  assign m1_arready = rstn && !m1_rd_act;
  assign m0_awready = rstn && !m0_wr_act;
  assign m0_wready  = rstn && (m0_wr_act || m0_awvalid);
  assign m1_awready = 1'b1;
  assign m1_wready  = 1'b1;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      m0_rd_act  <= 1'b0;
      m1_rd_act  <= 1'b0;
      m0_wr_act  <= 1'b0;
      m0_rd_addr <= '0;
      m1_rd_addr <= '0;
      m0_wr_addr <= '0;
      m0_rd_len  <= '0;
      m1_rd_len  <= '0;
      m0_rd_beat <= '0;
      m1_rd_beat <= '0;
      m0_rvalid  <= 1'b0;
      m1_rvalid  <= 1'b0;
      m0_rlast   <= 1'b0;
      m1_rlast   <= 1'b0;
      m0_bvalid  <= 1'b0;
      m1_bvalid  <= 1'b0;
      m0_rdata   <= '0;
      m1_rdata   <= '0;
      m0_rid     <= '0;
      m1_rid     <= '0;
      m0_rresp   <= AXI_RESP_OKAY;
      m1_rresp   <= AXI_RESP_OKAY;
      m0_bid     <= '0;
      m0_bresp   <= AXI_RESP_OKAY;
      m1_bid     <= '0;
      m1_bresp   <= AXI_RESP_OKAY;
    end else begin
      if (m0_arvalid && m0_arready) begin
        m0_rd_act  <= 1'b1;
        m0_rd_addr <= m0_araddr + 32'd4;
        m0_rd_len  <= m0_arlen;
        m0_rd_beat <= '0;
        m0_rid     <= m0_arid;
        m0_rdata   <= mem[word_addr(m0_araddr)];
        m0_rresp   <= AXI_RESP_OKAY;
        m0_rlast   <= (m0_arlen == 8'd0);
        m0_rvalid  <= 1'b1;
      end else if (m0_rvalid && m0_rready) begin
        if (m0_rlast) begin
          m0_rd_act <= 1'b0;
          m0_rvalid <= 1'b0;
          m0_rlast  <= 1'b0;
        end else begin
          m0_rdata   <= mem[word_addr(m0_rd_addr)];
          m0_rd_addr <= m0_rd_addr + 32'd4;
          m0_rd_beat <= m0_rd_beat + 8'd1;
          m0_rlast   <= (m0_rd_beat + 8'd1 == m0_rd_len);
        end
      end

      if (m1_arvalid && m1_arready) begin
        m1_rd_act  <= 1'b1;
        m1_rd_addr <= m1_araddr + 32'd4;
        m1_rd_len  <= m1_arlen;
        m1_rd_beat <= '0;
        m1_rid     <= m1_arid;
        m1_rdata   <= mem[word_addr(m1_araddr)];
        m1_rresp   <= AXI_RESP_OKAY;
        m1_rlast   <= (m1_arlen == 8'd0);
        m1_rvalid  <= 1'b1;
      end else if (m1_rvalid && m1_rready) begin
        if (m1_rlast) begin
          m1_rd_act <= 1'b0;
          m1_rvalid <= 1'b0;
          m1_rlast  <= 1'b0;
        end else begin
          m1_rdata   <= mem[word_addr(m1_rd_addr)];
          m1_rd_addr <= m1_rd_addr + 32'd4;
          m1_rd_beat <= m1_rd_beat + 8'd1;
          m1_rlast   <= (m1_rd_beat + 8'd1 == m1_rd_len);
        end
      end

      if (m0_bvalid && m0_bready) m0_bvalid <= 1'b0;

      if (m0_awvalid && m0_awready) begin
        m0_wr_act  <= 1'b1;
        m0_wr_addr <= m0_awaddr;
        m0_bid     <= m0_awid;
      end

      if (m0_wvalid && m0_wready) begin
        if (m0_wstrb[0]) mem[word_addr(m0_waddr_now)][7:0]   <= m0_wdata[7:0];
        if (m0_wstrb[1]) mem[word_addr(m0_waddr_now)][15:8]  <= m0_wdata[15:8];
        if (m0_wstrb[2]) mem[word_addr(m0_waddr_now)][23:16] <= m0_wdata[23:16];
        if (m0_wstrb[3]) mem[word_addr(m0_waddr_now)][31:24] <= m0_wdata[31:24];
        m0_wr_addr <= m0_waddr_now + 32'd4;
        if (m0_wlast) begin
          m0_wr_act <= 1'b0;
          m0_bvalid <= 1'b1;
          m0_bresp  <= AXI_RESP_OKAY;
        end
      end
    end
  end

  gemm_top dut (
      .clk            (clk),
      .rstn           (rstn),
      .s_axil_awaddr  (awaddr),
      .s_axil_awvalid (awvalid),
      .s_axil_awready (awready),
      .s_axil_wdata   (wdata),
      .s_axil_wstrb   (wstrb),
      .s_axil_wvalid  (wvalid),
      .s_axil_wready  (wready),
      .s_axil_bresp   (bresp),
      .s_axil_bvalid  (bvalid),
      .s_axil_bready  (bready),
      .s_axil_araddr  (araddr),
      .s_axil_arvalid (arvalid),
      .s_axil_arready (arready),
      .s_axil_rdata   (rdata),
      .s_axil_rresp   (rresp),
      .s_axil_rvalid  (rvalid),
      .s_axil_rready  (rready),
      .accel_hold     (hold),
      .gemm_busy      (busy),
      .pe_valid       (pe_valid),
      .dma_arvalid    (dma_arvalid),
      .dma_awvalid    (dma_awvalid),
      .status_done    (status_done),
      .m0_axi_arid    (m0_arid),
      .m0_axi_araddr  (m0_araddr),
      .m0_axi_arlen   (m0_arlen),
      .m0_axi_arsize  (m0_arsize),
      .m0_axi_arburst (m0_arburst),
      .m0_axi_arvalid (m0_arvalid),
      .m0_axi_arready (m0_arready),
      .m0_axi_rid     (m0_rid),
      .m0_axi_rdata   (m0_rdata),
      .m0_axi_rresp   (m0_rresp),
      .m0_axi_rlast   (m0_rlast),
      .m0_axi_rvalid  (m0_rvalid),
      .m0_axi_rready  (m0_rready),
      .m0_axi_awid    (m0_awid),
      .m0_axi_awaddr  (m0_awaddr),
      .m0_axi_awlen   (m0_awlen),
      .m0_axi_awsize  (m0_awsize),
      .m0_axi_awburst (m0_awburst),
      .m0_axi_awvalid (m0_awvalid),
      .m0_axi_awready (m0_awready),
      .m0_axi_wdata   (m0_wdata),
      .m0_axi_wstrb   (m0_wstrb),
      .m0_axi_wlast   (m0_wlast),
      .m0_axi_wvalid  (m0_wvalid),
      .m0_axi_wready  (m0_wready),
      .m0_axi_bid     (m0_bid),
      .m0_axi_bresp   (m0_bresp),
      .m0_axi_bvalid  (m0_bvalid),
      .m0_axi_bready  (m0_bready),
      .m1_axi_arid    (m1_arid),
      .m1_axi_araddr  (m1_araddr),
      .m1_axi_arlen   (m1_arlen),
      .m1_axi_arsize  (m1_arsize),
      .m1_axi_arburst (m1_arburst),
      .m1_axi_arvalid (m1_arvalid),
      .m1_axi_arready (m1_arready),
      .m1_axi_rid     (m1_rid),
      .m1_axi_rdata   (m1_rdata),
      .m1_axi_rresp   (m1_rresp),
      .m1_axi_rlast   (m1_rlast),
      .m1_axi_rvalid  (m1_rvalid),
      .m1_axi_rready  (m1_rready),
      .m1_axi_awid    (m1_awid),
      .m1_axi_awaddr  (m1_awaddr),
      .m1_axi_awlen   (m1_awlen),
      .m1_axi_awsize  (m1_awsize),
      .m1_axi_awburst (m1_awburst),
      .m1_axi_awvalid (m1_awvalid),
      .m1_axi_awready (m1_awready),
      .m1_axi_wdata   (m1_wdata),
      .m1_axi_wstrb   (m1_wstrb),
      .m1_axi_wlast   (m1_wlast),
      .m1_axi_wvalid  (m1_wvalid),
      .m1_axi_wready  (m1_wready),
      .m1_axi_bid     (m1_bid),
      .m1_axi_bresp   (m1_bresp),
      .m1_axi_bvalid  (m1_bvalid),
      .m1_axi_bready  (m1_bready)
  );

  assign bready = 1'b1;
  assign rready = 1'b1;

  task automatic axil_write(input logic [7:0] off, input logic [31:0] val);
    @(posedge clk);
    awaddr  <= {24'd0, off};
    awvalid <= 1'b1;
    wdata   <= val;
    wstrb   <= 4'hF;
    wvalid  <= 1'b1;
    do @(posedge clk); while (!(awready && wready));
    awvalid <= 1'b0;
    wvalid  <= 1'b0;
    do @(posedge clk); while (!bvalid);
  endtask

  task automatic store_byte(input logic [31:0] addr, input logic [7:0] b);
    logic [31:0] w;
    int idx, lane;
    idx  = word_addr(addr);
    lane = addr[1:0];
    w    = mem[idx];
    w[8*lane+:8] = b;
    mem[idx] = w;
  endtask

  function automatic logic [7:0] load_byte(input logic [31:0] addr);
    load_byte = mem[word_addr(addr)][8*addr[1:0]+:8];
  endfunction

  task automatic run_case(input int m, input int n, input int k, input int seed);
    int i, j, kk;
    int signed acc;
    logic [7:0] av, bv;
    logic [31:0] got, exp;
    int unsigned prng;
    prng = seed;
    M = m;
    N = n;
    K = k;
    errors = 0;
    for (i = 0; i < MEM_WORDS; i++) mem[i] = '0;
    for (i = 0; i < m; i++) begin
      for (kk = 0; kk < k; kk++) begin
        prng = prng * 1103515245 + 12345;
        store_byte(BASE_A + i * k + kk, prng[15:8]);
      end
    end
    for (kk = 0; kk < k; kk++) begin
      for (j = 0; j < n; j++) begin
        prng = prng * 1103515245 + 12345;
        store_byte(BASE_B + kk * n + j, prng[15:8]);
      end
    end

    axil_write(GEMM_OFF_BASE_A[7:0], BASE_A);
    axil_write(GEMM_OFF_BASE_B[7:0], BASE_B);
    axil_write(GEMM_OFF_BASE_C[7:0], BASE_C);
    axil_write(GEMM_OFF_M[7:0], m);
    axil_write(GEMM_OFF_N[7:0], n);
    axil_write(GEMM_OFF_K[7:0], k);
    t0 = cycles;
    axil_write(GEMM_OFF_CTRL[7:0], 32'd1);
    begin
      int guard;
      guard = 0;
      while (!status_done) begin
        @(posedge clk);
        guard++;
        if (guard > 50000000) $fatal(1, "timeout waiting for gemm done");
      end
    end
    @(posedge clk);

    for (i = 0; i < m; i++) begin
      for (j = 0; j < n; j++) begin
        acc = 0;
        for (kk = 0; kk < k; kk++) begin
          av  = load_byte(BASE_A + i * k + kk);
          bv  = load_byte(BASE_B + kk * n + j);
          acc = acc + s8(av) * s8(bv);
        end
        exp = acc;
        got = mem[word_addr(BASE_C + 4 * (i * n + j))];
        if (got !== exp) begin
          errors++;
          if (errors < 8)
            $display("MISMATCH C[%0d,%0d] got %0d exp %0d", i, j, $signed(got), $signed(exp));
        end
      end
    end
    $display("CASE M=%0d N=%0d K=%0d seed=%0d cycles=%0d errors=%0d", m, n, k, seed,
             cycles - t0, errors);
    if (errors != 0) $fatal(1, "gemm_top_tb failed");
  endtask

  always_ff @(posedge clk) begin
    if (!rstn) cycles <= 0;
    else cycles <= cycles + 1;
  end

  initial begin
    awvalid = 0;
    wvalid  = 0;
    arvalid = 0;
    wstrb   = 4'hF;
    rstn    = 0;
    repeat (8) @(posedge clk);
    rstn = 1;
    repeat (4) @(posedge clk);

    if (!$value$plusargs("M=%d", M)) M = 8;
    if (!$value$plusargs("N=%d", N)) N = 8;
    if (!$value$plusargs("K=%d", K)) K = 8;
    if (!$value$plusargs("SEED=%d", SEED)) SEED = 1;
    if (!$value$plusargs("NSEED=%d", NSEED)) NSEED = 0;

    if ($test$plusargs("directed")) begin
      run_case(8, 8, 8, 1);
      run_case(8, 8, 32, 2);
      run_case(5, 7, 9, 3);
    end else if (NSEED > 0) begin
      for (int s = 1; s <= NSEED; s++) run_case(M, N, K, s);
    end else begin
      run_case(M, N, K, SEED);
    end
    $display("PASS");
    $finish;
  end

endmodule
