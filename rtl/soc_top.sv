///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Tiny Vedas SoC Top (core + AXI4 adapters + on-chip memories)

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

`ifndef MMIO_MAP_SVH
`include "mmio_map.svh"
`endif

`ifndef GEMM_CSRS_SVH
`include "gemm_csrs.svh"
`endif

module soc_top #(
    parameter string ICCM_INIT_FILE = "",
    parameter string DCCM_INIT_FILE = "",
    parameter logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h80000000
) (

    input logic            clk,
    input logic            rstn,
    input logic [XLEN-1:0] reset_vector
`ifndef SYNTHESIS
    ,
    output core_debug_lane_t core_debug[ISSUE_WIDTH-1:0],
    output logic            mmio_dev_we    [MMIO_DEV_COUNT-1:0],
    output logic [XLEN-1:0] mmio_dev_wdata [MMIO_DEV_COUNT-1:0],
    output logic            accel_hold,
    output logic            gemm_busy
`endif

);

  logic      [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr;
  logic                                 instr_mem_addr_valid;
  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_out;
  logic      [     INSTR_MEM_WIDTH-1:0] instr_mem_rdata;
  logic                                 instr_mem_rdata_valid;
  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in;

  logic [XLEN-1:0] dccm_raddr     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_rvalid_in [LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dccm_rdata     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_rvalid_out[LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dccm_waddr     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_wen       [LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dccm_wdata     [LSU_DCCM_PORT_COUNT-1:0];
  logic [     3:0] dccm_wstrb     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_wen_mem   [LSU_DCCM_PORT_COUNT-1:0];
`ifdef SYNTHESIS
  logic            mmio_dev_we    [MMIO_DEV_COUNT-1:0];
  logic [XLEN-1:0] mmio_dev_wdata [MMIO_DEV_COUNT-1:0];
`endif
  logic [XLEN-1:0] mmio_dev_addr  [MMIO_DEV_COUNT-1:0];
  logic            accel_hold_w;
  logic            gemm_busy_w;
`ifdef SYNTHESIS
  logic            accel_hold;
  logic            gemm_busy;
`endif
  assign accel_hold = accel_hold_w;
  assign gemm_busy  = gemm_busy_w;

  function automatic logic gemm_addr_hit(input logic [31:0] a);
    return (a >= MMIO_GEMM_ADDR) && (a < (MMIO_GEMM_ADDR + MMIO_GEMM_SIZE));
  endfunction

  core_top #(
      .STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)
  ) core_i (
      .clk                  (clk),
      .rstn                 (rstn),
      .reset_vector         (reset_vector),
      .instr_mem_addr       (instr_mem_addr),
      .instr_mem_addr_valid (instr_mem_addr_valid),
      .instr_mem_tag_out    (instr_mem_tag_out),
      .instr_mem_rdata      (instr_mem_rdata),
      .instr_mem_rdata_valid(instr_mem_rdata_valid),
      .instr_mem_tag_in     (instr_mem_tag_in),
      .dccm_raddr           (dccm_raddr),
      .dccm_rvalid_in       (dccm_rvalid_in),
      .dccm_rdata           (dccm_rdata),
      .dccm_rvalid_out      (dccm_rvalid_out),
      .dccm_waddr           (dccm_waddr),
      .dccm_wen             (dccm_wen),
      .dccm_wdata           (dccm_wdata),
      .dccm_wstrb           (dccm_wstrb),
      .accel_hold           (accel_hold_w)
`ifndef SYNTHESIS
      ,
      .debug(core_debug)
`endif
  );

  genvar gp;
  mmio_mux u_mmio (
      .addr     (dccm_waddr),
      .wen      (dccm_wen),
      .wdata    (dccm_wdata),
      .mem_wen  (dccm_wen_mem),
      .dev_we   (mmio_dev_we),
      .dev_addr (mmio_dev_addr),
      .dev_wdata(mmio_dev_wdata)
  );

  logic [   AXI_ID_WIDTH-1:0] imem_arid;
  logic [ AXI_ADDR_WIDTH-1:0] imem_araddr;
  logic [   AXI_LEN_WIDTH-1:0] imem_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] imem_arsize;
  logic [ AXI_BURST_WIDTH-1:0] imem_arburst;
  logic                        imem_arvalid;
  logic                        imem_arready;
  logic [   AXI_ID_WIDTH-1:0] imem_rid;
  logic [AXI_DATA_WIDTH-1:0]  imem_rdata;
  logic [ AXI_RESP_WIDTH-1:0] imem_rresp;
  logic                        imem_rlast;
  logic                        imem_rvalid;
  logic                        imem_rready;

  imem_to_axi4 u_imem_ad (
      .clk                  (clk),
      .rstn                 (rstn),
      .instr_mem_addr       (instr_mem_addr),
      .instr_mem_addr_valid (instr_mem_addr_valid),
      .instr_mem_tag_out    (instr_mem_tag_out),
      .instr_mem_rdata      (instr_mem_rdata),
      .instr_mem_rdata_valid(instr_mem_rdata_valid),
      .instr_mem_tag_in     (instr_mem_tag_in),
      .m_axi_arid           (imem_arid),
      .m_axi_araddr         (imem_araddr),
      .m_axi_arlen          (imem_arlen),
      .m_axi_arsize         (imem_arsize),
      .m_axi_arburst        (imem_arburst),
      .m_axi_arvalid        (imem_arvalid),
      .m_axi_arready        (imem_arready),
      .m_axi_rid            (imem_rid),
      .m_axi_rdata          (imem_rdata),
      .m_axi_rresp          (imem_rresp),
      .m_axi_rlast          (imem_rlast),
      .m_axi_rvalid         (imem_rvalid),
      .m_axi_rready         (imem_rready)
  );

  axi4_iccm #(
      .DEPTH(INSTR_MEM_DEPTH),
      .WIDTH(INSTR_MEM_WIDTH),
      .INIT_FILE(ICCM_INIT_FILE)
  ) u_iccm (
      .clk          (clk),
      .rstn         (rstn),
      .s_axi_arid   (imem_arid),
      .s_axi_araddr (imem_araddr),
      .s_axi_arlen  (imem_arlen),
      .s_axi_arsize (imem_arsize),
      .s_axi_arburst(imem_arburst),
      .s_axi_arvalid(imem_arvalid),
      .s_axi_arready(imem_arready),
      .s_axi_rid    (imem_rid),
      .s_axi_rdata  (imem_rdata),
      .s_axi_rresp  (imem_rresp),
      .s_axi_rlast  (imem_rlast),
      .s_axi_rvalid (imem_rvalid),
      .s_axi_rready (imem_rready),
      .host_wen     (1'b0),
      .host_waddr   ('0),
      .host_wdata   ('0),
      .host_wstrb   ('0),
      .host_ren     (1'b0),
      .host_raddr   ('0),
      .host_rdata   (),
      .host_rvalid  ()
  );

  logic [   AXI_ID_WIDTH-1:0] dmem_arid     [LSU_DCCM_PORT_COUNT-1:0];
  logic [ AXI_ADDR_WIDTH-1:0] dmem_araddr   [LSU_DCCM_PORT_COUNT-1:0];
  logic [   AXI_LEN_WIDTH-1:0] dmem_arlen    [LSU_DCCM_PORT_COUNT-1:0];
  logic [  AXI_SIZE_WIDTH-1:0] dmem_arsize   [LSU_DCCM_PORT_COUNT-1:0];
  logic [ AXI_BURST_WIDTH-1:0] dmem_arburst  [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_arvalid  [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_arready  [LSU_DCCM_PORT_COUNT-1:0];
  logic [   AXI_ID_WIDTH-1:0] dmem_rid      [LSU_DCCM_PORT_COUNT-1:0];
  logic [AXI_DATA_WIDTH-1:0]  dmem_rdata_axi[LSU_DCCM_PORT_COUNT-1:0];
  logic [ AXI_RESP_WIDTH-1:0] dmem_rresp    [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_rlast    [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_rvalid   [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_rready   [LSU_DCCM_PORT_COUNT-1:0];

  logic [   AXI_ID_WIDTH-1:0] dmem_awid     [LSU_DCCM_PORT_COUNT-1:0];
  logic [ AXI_ADDR_WIDTH-1:0] dmem_awaddr   [LSU_DCCM_PORT_COUNT-1:0];
  logic [   AXI_LEN_WIDTH-1:0] dmem_awlen    [LSU_DCCM_PORT_COUNT-1:0];
  logic [  AXI_SIZE_WIDTH-1:0] dmem_awsize   [LSU_DCCM_PORT_COUNT-1:0];
  logic [ AXI_BURST_WIDTH-1:0] dmem_awburst  [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_awvalid  [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_awready  [LSU_DCCM_PORT_COUNT-1:0];
  logic [AXI_DATA_WIDTH-1:0]  dmem_wdata_axi[LSU_DCCM_PORT_COUNT-1:0];
  logic [AXI_STRB_WIDTH-1:0]  dmem_wstrb_axi[LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_wlast    [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_wvalid   [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_wready   [LSU_DCCM_PORT_COUNT-1:0];
  logic [   AXI_ID_WIDTH-1:0] dmem_bid      [LSU_DCCM_PORT_COUNT-1:0];
  logic [ AXI_RESP_WIDTH-1:0] dmem_bresp    [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_bvalid   [LSU_DCCM_PORT_COUNT-1:0];
  logic                        dmem_bready   [LSU_DCCM_PORT_COUNT-1:0];

  logic [XLEN-1:0] lsu_rdata      [LSU_DCCM_PORT_COUNT-1:0];
  logic            lsu_rvalid_out [LSU_DCCM_PORT_COUNT-1:0];
  logic            gemm_rd_hit    [LSU_DCCM_PORT_COUNT-1:0];
  logic            gemm_rd_hit_q  [LSU_DCCM_PORT_COUNT-1:0];

  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_dmem_ad
      assign gemm_rd_hit[gp] = dccm_rvalid_in[gp] && gemm_addr_hit(dccm_raddr[gp]);
      dmem_to_axi4 u_dmem_ad (
          .clk            (clk),
          .rstn           (rstn),
          .dccm_raddr     (dccm_raddr[gp]),
          .dccm_rvalid_in (dccm_rvalid_in[gp] && !gemm_rd_hit[gp] && !gemm_busy_w),
          .dccm_rdata     (lsu_rdata[gp]),
          .dccm_rvalid_out(lsu_rvalid_out[gp]),
          .dccm_waddr     (dccm_waddr[gp]),
          .dccm_wen       (dccm_wen_mem[gp]),
          .dccm_wdata     (dccm_wdata[gp]),
          .dccm_wstrb     (dccm_wstrb[gp]),
          .m_axi_arid     (dmem_arid[gp]),
          .m_axi_araddr   (dmem_araddr[gp]),
          .m_axi_arlen    (dmem_arlen[gp]),
          .m_axi_arsize   (dmem_arsize[gp]),
          .m_axi_arburst  (dmem_arburst[gp]),
          .m_axi_arvalid  (dmem_arvalid[gp]),
          .m_axi_arready  (dmem_arready[gp]),
          .m_axi_rid      (dmem_rid[gp]),
          .m_axi_rdata    (dmem_rdata_axi[gp]),
          .m_axi_rresp    (dmem_rresp[gp]),
          .m_axi_rlast    (dmem_rlast[gp]),
          .m_axi_rvalid   (dmem_rvalid[gp]),
          .m_axi_rready   (dmem_rready[gp]),
          .m_axi_awid     (dmem_awid[gp]),
          .m_axi_awaddr   (dmem_awaddr[gp]),
          .m_axi_awlen    (dmem_awlen[gp]),
          .m_axi_awsize   (dmem_awsize[gp]),
          .m_axi_awburst  (dmem_awburst[gp]),
          .m_axi_awvalid  (dmem_awvalid[gp]),
          .m_axi_awready  (dmem_awready[gp]),
          .m_axi_wdata    (dmem_wdata_axi[gp]),
          .m_axi_wstrb    (dmem_wstrb_axi[gp]),
          .m_axi_wlast    (dmem_wlast[gp]),
          .m_axi_wvalid   (dmem_wvalid[gp]),
          .m_axi_wready   (dmem_wready[gp]),
          .m_axi_bid      (dmem_bid[gp]),
          .m_axi_bresp    (dmem_bresp[gp]),
          .m_axi_bvalid   (dmem_bvalid[gp]),
          .m_axi_bready   (dmem_bready[gp])
      );
    end
  endgenerate

  logic [AXI_ADDR_WIDTH-1:0] gemm_awaddr;
  logic                      gemm_awvalid, gemm_awready;
  logic [AXI_DATA_WIDTH-1:0] gemm_wdata;
  logic [AXI_STRB_WIDTH-1:0] gemm_wstrb;
  logic                      gemm_wvalid, gemm_wready;
  logic [AXI_RESP_WIDTH-1:0] gemm_bresp;
  logic                      gemm_bvalid, gemm_bready;
  logic [AXI_ADDR_WIDTH-1:0] gemm_araddr;
  logic                      gemm_arvalid, gemm_arready;
  logic [AXI_DATA_WIDTH-1:0] gemm_rdata;
  logic [AXI_RESP_WIDTH-1:0] gemm_rresp;
  logic                      gemm_rvalid, gemm_rready;

  logic gemm_rd_any;
  logic [31:0] gemm_rd_addr;
  always_comb begin
    gemm_rd_any  = 1'b0;
    gemm_rd_addr = '0;
    for (int unsigned p = 0; p < LSU_DCCM_PORT_COUNT; p++) begin
      if (gemm_rd_hit[p]) begin
        gemm_rd_any  = 1'b1;
        gemm_rd_addr = dccm_raddr[p];
      end
    end
  end

  assign gemm_awaddr  = mmio_dev_addr[MMIO_IDX_GEMM];
  assign gemm_awvalid = mmio_dev_we[MMIO_IDX_GEMM];
  assign gemm_wdata   = mmio_dev_wdata[MMIO_IDX_GEMM];
  assign gemm_wstrb   = 4'hF;
  assign gemm_wvalid  = mmio_dev_we[MMIO_IDX_GEMM];
  assign gemm_bready  = 1'b1;
  assign gemm_araddr  = gemm_rd_addr;
  assign gemm_arvalid = gemm_rd_any;
  assign gemm_rready  = 1'b1;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      for (int unsigned p = 0; p < LSU_DCCM_PORT_COUNT; p++) gemm_rd_hit_q[p] <= 1'b0;
    end else begin
      for (int unsigned p = 0; p < LSU_DCCM_PORT_COUNT; p++) gemm_rd_hit_q[p] <= gemm_rd_hit[p];
    end
  end

  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_rdata_mux
      assign dccm_rdata[gp]      = gemm_rd_hit_q[gp] ? gemm_rdata : lsu_rdata[gp];
      assign dccm_rvalid_out[gp] = gemm_rd_hit_q[gp] ? gemm_rvalid : lsu_rvalid_out[gp];
    end
  endgenerate

  /* GEMM DMA AXI masters */
  logic [   AXI_ID_WIDTH-1:0] g0_arid, g1_arid;
  logic [ AXI_ADDR_WIDTH-1:0] g0_araddr, g1_araddr;
  logic [   AXI_LEN_WIDTH-1:0] g0_arlen, g1_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] g0_arsize, g1_arsize;
  logic [ AXI_BURST_WIDTH-1:0] g0_arburst, g1_arburst;
  logic                        g0_arvalid, g1_arvalid, g0_arready, g1_arready;
  logic [   AXI_ID_WIDTH-1:0] g0_rid, g1_rid;
  logic [AXI_DATA_WIDTH-1:0]  g0_rdata, g1_rdata;
  logic [ AXI_RESP_WIDTH-1:0] g0_rresp, g1_rresp;
  logic                        g0_rlast, g1_rlast, g0_rvalid, g1_rvalid, g0_rready, g1_rready;
  logic [   AXI_ID_WIDTH-1:0] g0_awid, g1_awid;
  logic [ AXI_ADDR_WIDTH-1:0] g0_awaddr, g1_awaddr;
  logic [   AXI_LEN_WIDTH-1:0] g0_awlen, g1_awlen;
  logic [  AXI_SIZE_WIDTH-1:0] g0_awsize, g1_awsize;
  logic [ AXI_BURST_WIDTH-1:0] g0_awburst, g1_awburst;
  logic                        g0_awvalid, g1_awvalid, g0_awready, g1_awready;
  logic [AXI_DATA_WIDTH-1:0]  g0_wdata, g1_wdata;
  logic [AXI_STRB_WIDTH-1:0]  g0_wstrb, g1_wstrb;
  logic                        g0_wlast, g1_wlast, g0_wvalid, g1_wvalid, g0_wready, g1_wready;
  logic [   AXI_ID_WIDTH-1:0] g0_bid, g1_bid;
  logic [ AXI_RESP_WIDTH-1:0] g0_bresp, g1_bresp;
  logic                        g0_bvalid, g1_bvalid, g0_bready, g1_bready;

  logic [   AXI_ID_WIDTH-1:0] s0_arid, s1_arid;
  logic [ AXI_ADDR_WIDTH-1:0] s0_araddr, s1_araddr;
  logic [   AXI_LEN_WIDTH-1:0] s0_arlen, s1_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] s0_arsize, s1_arsize;
  logic [ AXI_BURST_WIDTH-1:0] s0_arburst, s1_arburst;
  logic                        s0_arvalid, s1_arvalid, s0_arready, s1_arready;
  logic [   AXI_ID_WIDTH-1:0] s0_rid, s1_rid;
  logic [AXI_DATA_WIDTH-1:0]  s0_rdata, s1_rdata;
  logic [ AXI_RESP_WIDTH-1:0] s0_rresp, s1_rresp;
  logic                        s0_rlast, s1_rlast, s0_rvalid, s1_rvalid, s0_rready, s1_rready;
  logic [   AXI_ID_WIDTH-1:0] s0_awid, s1_awid;
  logic [ AXI_ADDR_WIDTH-1:0] s0_awaddr, s1_awaddr;
  logic [   AXI_LEN_WIDTH-1:0] s0_awlen, s1_awlen;
  logic [  AXI_SIZE_WIDTH-1:0] s0_awsize, s1_awsize;
  logic [ AXI_BURST_WIDTH-1:0] s0_awburst, s1_awburst;
  logic                        s0_awvalid, s1_awvalid, s0_awready, s1_awready;
  logic [AXI_DATA_WIDTH-1:0]  s0_wdata, s1_wdata;
  logic [AXI_STRB_WIDTH-1:0]  s0_wstrb, s1_wstrb;
  logic                        s0_wlast, s1_wlast, s0_wvalid, s1_wvalid, s0_wready, s1_wready;
  logic [   AXI_ID_WIDTH-1:0] s0_bid, s1_bid;
  logic [ AXI_RESP_WIDTH-1:0] s0_bresp, s1_bresp;
  logic                        s0_bvalid, s1_bvalid, s0_bready, s1_bready;

  gemm_top u_gemm (
      .clk            (clk),
      .rstn           (rstn),
      .s_axil_awaddr  (gemm_awaddr),
      .s_axil_awvalid (gemm_awvalid),
      .s_axil_awready (gemm_awready),
      .s_axil_wdata   (gemm_wdata),
      .s_axil_wstrb   (gemm_wstrb),
      .s_axil_wvalid  (gemm_wvalid),
      .s_axil_wready  (gemm_wready),
      .s_axil_bresp   (gemm_bresp),
      .s_axil_bvalid  (gemm_bvalid),
      .s_axil_bready  (gemm_bready),
      .s_axil_araddr  (gemm_araddr),
      .s_axil_arvalid (gemm_arvalid),
      .s_axil_arready (gemm_arready),
      .s_axil_rdata   (gemm_rdata),
      .s_axil_rresp   (gemm_rresp),
      .s_axil_rvalid  (gemm_rvalid),
      .s_axil_rready  (gemm_rready),
      .accel_hold     (accel_hold_w),
      .gemm_busy      (gemm_busy_w),
      .pe_valid       (),
      .dma_arvalid    (),
      .dma_awvalid    (),
      .status_done    (),
      .m0_axi_arid    (g0_arid),
      .m0_axi_araddr  (g0_araddr),
      .m0_axi_arlen   (g0_arlen),
      .m0_axi_arsize  (g0_arsize),
      .m0_axi_arburst (g0_arburst),
      .m0_axi_arvalid (g0_arvalid),
      .m0_axi_arready (g0_arready),
      .m0_axi_rid     (g0_rid),
      .m0_axi_rdata   (g0_rdata),
      .m0_axi_rresp   (g0_rresp),
      .m0_axi_rlast   (g0_rlast),
      .m0_axi_rvalid  (g0_rvalid),
      .m0_axi_rready  (g0_rready),
      .m0_axi_awid    (g0_awid),
      .m0_axi_awaddr  (g0_awaddr),
      .m0_axi_awlen   (g0_awlen),
      .m0_axi_awsize  (g0_awsize),
      .m0_axi_awburst (g0_awburst),
      .m0_axi_awvalid (g0_awvalid),
      .m0_axi_awready (g0_awready),
      .m0_axi_wdata   (g0_wdata),
      .m0_axi_wstrb   (g0_wstrb),
      .m0_axi_wlast   (g0_wlast),
      .m0_axi_wvalid  (g0_wvalid),
      .m0_axi_wready  (g0_wready),
      .m0_axi_bid     (g0_bid),
      .m0_axi_bresp   (g0_bresp),
      .m0_axi_bvalid  (g0_bvalid),
      .m0_axi_bready  (g0_bready),
      .m1_axi_arid    (g1_arid),
      .m1_axi_araddr  (g1_araddr),
      .m1_axi_arlen   (g1_arlen),
      .m1_axi_arsize  (g1_arsize),
      .m1_axi_arburst (g1_arburst),
      .m1_axi_arvalid (g1_arvalid),
      .m1_axi_arready (g1_arready),
      .m1_axi_rid     (g1_rid),
      .m1_axi_rdata   (g1_rdata),
      .m1_axi_rresp   (g1_rresp),
      .m1_axi_rlast   (g1_rlast),
      .m1_axi_rvalid  (g1_rvalid),
      .m1_axi_rready  (g1_rready),
      .m1_axi_awid    (g1_awid),
      .m1_axi_awaddr  (g1_awaddr),
      .m1_axi_awlen   (g1_awlen),
      .m1_axi_awsize  (g1_awsize),
      .m1_axi_awburst (g1_awburst),
      .m1_axi_awvalid (g1_awvalid),
      .m1_axi_awready (g1_awready),
      .m1_axi_wdata   (g1_wdata),
      .m1_axi_wstrb   (g1_wstrb),
      .m1_axi_wlast   (g1_wlast),
      .m1_axi_wvalid  (g1_wvalid),
      .m1_axi_wready  (g1_wready),
      .m1_axi_bid     (g1_bid),
      .m1_axi_bresp   (g1_bresp),
      .m1_axi_bvalid  (g1_bvalid),
      .m1_axi_bready  (g1_bready)
  );

  axi4_mst_sel u_mux0 (
      .sel_b     (gemm_busy_w),
      .a_arid    (dmem_arid[0]),
      .a_araddr  (dmem_araddr[0]),
      .a_arlen   (dmem_arlen[0]),
      .a_arsize  (dmem_arsize[0]),
      .a_arburst (dmem_arburst[0]),
      .a_arvalid (dmem_arvalid[0]),
      .a_arready (dmem_arready[0]),
      .a_rid     (dmem_rid[0]),
      .a_rdata   (dmem_rdata_axi[0]),
      .a_rresp   (dmem_rresp[0]),
      .a_rlast   (dmem_rlast[0]),
      .a_rvalid  (dmem_rvalid[0]),
      .a_rready  (dmem_rready[0]),
      .a_awid    (dmem_awid[0]),
      .a_awaddr  (dmem_awaddr[0]),
      .a_awlen   (dmem_awlen[0]),
      .a_awsize  (dmem_awsize[0]),
      .a_awburst (dmem_awburst[0]),
      .a_awvalid (dmem_awvalid[0]),
      .a_awready (dmem_awready[0]),
      .a_wdata   (dmem_wdata_axi[0]),
      .a_wstrb   (dmem_wstrb_axi[0]),
      .a_wlast   (dmem_wlast[0]),
      .a_wvalid  (dmem_wvalid[0]),
      .a_wready  (dmem_wready[0]),
      .a_bid     (dmem_bid[0]),
      .a_bresp   (dmem_bresp[0]),
      .a_bvalid  (dmem_bvalid[0]),
      .a_bready  (dmem_bready[0]),
      .b_arid    (g0_arid),
      .b_araddr  (g0_araddr),
      .b_arlen   (g0_arlen),
      .b_arsize  (g0_arsize),
      .b_arburst (g0_arburst),
      .b_arvalid (g0_arvalid),
      .b_arready (g0_arready),
      .b_rid     (g0_rid),
      .b_rdata   (g0_rdata),
      .b_rresp   (g0_rresp),
      .b_rlast   (g0_rlast),
      .b_rvalid  (g0_rvalid),
      .b_rready  (g0_rready),
      .b_awid    (g0_awid),
      .b_awaddr  (g0_awaddr),
      .b_awlen   (g0_awlen),
      .b_awsize  (g0_awsize),
      .b_awburst (g0_awburst),
      .b_awvalid (g0_awvalid),
      .b_awready (g0_awready),
      .b_wdata   (g0_wdata),
      .b_wstrb   (g0_wstrb),
      .b_wlast   (g0_wlast),
      .b_wvalid  (g0_wvalid),
      .b_wready  (g0_wready),
      .b_bid     (g0_bid),
      .b_bresp   (g0_bresp),
      .b_bvalid  (g0_bvalid),
      .b_bready  (g0_bready),
      .s_arid    (s0_arid),
      .s_araddr  (s0_araddr),
      .s_arlen   (s0_arlen),
      .s_arsize  (s0_arsize),
      .s_arburst (s0_arburst),
      .s_arvalid (s0_arvalid),
      .s_arready (s0_arready),
      .s_rid     (s0_rid),
      .s_rdata   (s0_rdata),
      .s_rresp   (s0_rresp),
      .s_rlast   (s0_rlast),
      .s_rvalid  (s0_rvalid),
      .s_rready  (s0_rready),
      .s_awid    (s0_awid),
      .s_awaddr  (s0_awaddr),
      .s_awlen   (s0_awlen),
      .s_awsize  (s0_awsize),
      .s_awburst (s0_awburst),
      .s_awvalid (s0_awvalid),
      .s_awready (s0_awready),
      .s_wdata   (s0_wdata),
      .s_wstrb   (s0_wstrb),
      .s_wlast   (s0_wlast),
      .s_wvalid  (s0_wvalid),
      .s_wready  (s0_wready),
      .s_bid     (s0_bid),
      .s_bresp   (s0_bresp),
      .s_bvalid  (s0_bvalid),
      .s_bready  (s0_bready)
  );

  axi4_mst_sel u_mux1 (
      .sel_b     (gemm_busy_w),
      .a_arid    (dmem_arid[1]),
      .a_araddr  (dmem_araddr[1]),
      .a_arlen   (dmem_arlen[1]),
      .a_arsize  (dmem_arsize[1]),
      .a_arburst (dmem_arburst[1]),
      .a_arvalid (dmem_arvalid[1]),
      .a_arready (dmem_arready[1]),
      .a_rid     (dmem_rid[1]),
      .a_rdata   (dmem_rdata_axi[1]),
      .a_rresp   (dmem_rresp[1]),
      .a_rlast   (dmem_rlast[1]),
      .a_rvalid  (dmem_rvalid[1]),
      .a_rready  (dmem_rready[1]),
      .a_awid    (dmem_awid[1]),
      .a_awaddr  (dmem_awaddr[1]),
      .a_awlen   (dmem_awlen[1]),
      .a_awsize  (dmem_awsize[1]),
      .a_awburst (dmem_awburst[1]),
      .a_awvalid (dmem_awvalid[1]),
      .a_awready (dmem_awready[1]),
      .a_wdata   (dmem_wdata_axi[1]),
      .a_wstrb   (dmem_wstrb_axi[1]),
      .a_wlast   (dmem_wlast[1]),
      .a_wvalid  (dmem_wvalid[1]),
      .a_wready  (dmem_wready[1]),
      .a_bid     (dmem_bid[1]),
      .a_bresp   (dmem_bresp[1]),
      .a_bvalid  (dmem_bvalid[1]),
      .a_bready  (dmem_bready[1]),
      .b_arid    (g1_arid),
      .b_araddr  (g1_araddr),
      .b_arlen   (g1_arlen),
      .b_arsize  (g1_arsize),
      .b_arburst (g1_arburst),
      .b_arvalid (g1_arvalid),
      .b_arready (g1_arready),
      .b_rid     (g1_rid),
      .b_rdata   (g1_rdata),
      .b_rresp   (g1_rresp),
      .b_rlast   (g1_rlast),
      .b_rvalid  (g1_rvalid),
      .b_rready  (g1_rready),
      .b_awid    (g1_awid),
      .b_awaddr  (g1_awaddr),
      .b_awlen   (g1_awlen),
      .b_awsize  (g1_awsize),
      .b_awburst (g1_awburst),
      .b_awvalid (g1_awvalid),
      .b_awready (g1_awready),
      .b_wdata   (g1_wdata),
      .b_wstrb   (g1_wstrb),
      .b_wlast   (g1_wlast),
      .b_wvalid  (g1_wvalid),
      .b_wready  (g1_wready),
      .b_bid     (g1_bid),
      .b_bresp   (g1_bresp),
      .b_bvalid  (g1_bvalid),
      .b_bready  (g1_bready),
      .s_arid    (s1_arid),
      .s_araddr  (s1_araddr),
      .s_arlen   (s1_arlen),
      .s_arsize  (s1_arsize),
      .s_arburst (s1_arburst),
      .s_arvalid (s1_arvalid),
      .s_arready (s1_arready),
      .s_rid     (s1_rid),
      .s_rdata   (s1_rdata),
      .s_rresp   (s1_rresp),
      .s_rlast   (s1_rlast),
      .s_rvalid  (s1_rvalid),
      .s_rready  (s1_rready),
      .s_awid    (s1_awid),
      .s_awaddr  (s1_awaddr),
      .s_awlen   (s1_awlen),
      .s_awsize  (s1_awsize),
      .s_awburst (s1_awburst),
      .s_awvalid (s1_awvalid),
      .s_awready (s1_awready),
      .s_wdata   (s1_wdata),
      .s_wstrb   (s1_wstrb),
      .s_wlast   (s1_wlast),
      .s_wvalid  (s1_wvalid),
      .s_wready  (s1_wready),
      .s_bid     (s1_bid),
      .s_bresp   (s1_bresp),
      .s_bvalid  (s1_bvalid),
      .s_bready  (s1_bready)
  );

  axi4_dccm #(
      .DEPTH(DATA_MEM_DEPTH),
      .WIDTH(DATA_MEM_WIDTH),
      .INIT_FILE(DCCM_INIT_FILE)
  ) u_dccm (
      .clk          (clk),
      .rstn         (rstn),
      .s_axi_arid   (s0_arid),
      .s_axi_araddr (s0_araddr),
      .s_axi_arlen  (s0_arlen),
      .s_axi_arsize (s0_arsize),
      .s_axi_arburst(s0_arburst),
      .s_axi_arvalid(s0_arvalid),
      .s_axi_arready(s0_arready),
      .s_axi_rid    (s0_rid),
      .s_axi_rdata  (s0_rdata),
      .s_axi_rresp  (s0_rresp),
      .s_axi_rlast  (s0_rlast),
      .s_axi_rvalid (s0_rvalid),
      .s_axi_rready (s0_rready),
      .s_axi_awid   (s0_awid),
      .s_axi_awaddr (s0_awaddr),
      .s_axi_awlen  (s0_awlen),
      .s_axi_awsize (s0_awsize),
      .s_axi_awburst(s0_awburst),
      .s_axi_awvalid(s0_awvalid),
      .s_axi_awready(s0_awready),
      .s_axi_wdata  (s0_wdata),
      .s_axi_wstrb  (s0_wstrb),
      .s_axi_wlast  (s0_wlast),
      .s_axi_wvalid (s0_wvalid),
      .s_axi_wready (s0_wready),
      .s_axi_bid    (s0_bid),
      .s_axi_bresp  (s0_bresp),
      .s_axi_bvalid (s0_bvalid),
      .s_axi_bready (s0_bready),
      .s1_axi_arid   (s1_arid),
      .s1_axi_araddr (s1_araddr),
      .s1_axi_arlen  (s1_arlen),
      .s1_axi_arsize (s1_arsize),
      .s1_axi_arburst(s1_arburst),
      .s1_axi_arvalid(s1_arvalid),
      .s1_axi_arready(s1_arready),
      .s1_axi_rid    (s1_rid),
      .s1_axi_rdata  (s1_rdata),
      .s1_axi_rresp  (s1_rresp),
      .s1_axi_rlast  (s1_rlast),
      .s1_axi_rvalid (s1_rvalid),
      .s1_axi_rready (s1_rready),
      .s1_axi_awid   (s1_awid),
      .s1_axi_awaddr (s1_awaddr),
      .s1_axi_awlen  (s1_awlen),
      .s1_axi_awsize (s1_awsize),
      .s1_axi_awburst(s1_awburst),
      .s1_axi_awvalid(s1_awvalid),
      .s1_axi_awready(s1_awready),
      .s1_axi_wdata  (s1_wdata),
      .s1_axi_wstrb  (s1_wstrb),
      .s1_axi_wlast  (s1_wlast),
      .s1_axi_wvalid (s1_wvalid),
      .s1_axi_wready (s1_wready),
      .s1_axi_bid    (s1_bid),
      .s1_axi_bresp  (s1_bresp),
      .s1_axi_bvalid (s1_bvalid),
      .s1_axi_bready (s1_bready),
      .host_sel     (1'b0),
      .host_en      (1'b0),
      .host_wr      (1'b0),
      .host_addr    ('0),
      .host_din     ('0),
      .host_wstrb   ('0),
      .host_dout    (),
      .host_rvalid  ()
  );

  logic unused_axil = &{1'b0, gemm_awready, gemm_wready, gemm_bresp, gemm_bvalid, gemm_arready,
                        gemm_rresp};

endmodule
