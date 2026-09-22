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
    parameter string DRAM_INIT_FILE = "",
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

  logic        v_req, v_wen, v_rvalid;
  logic [31:0] v_addr;
  logic [127:0] v_wdata, v_rdata;
  logic [15:0] v_wstrb;

  function automatic logic gemm_addr_hit(input logic [31:0] a);
    return (a >= MMIO_GEMM_ADDR) && (a < (MMIO_GEMM_ADDR + MMIO_GEMM_SIZE));
  endfunction

  function automatic logic dram_addr_hit(input logic [31:0] a);
    return (a >= DRAM_BASE) && (a < (DRAM_BASE + DRAM_BYTES));
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
      .accel_hold           (accel_hold_w),
      .v_dccm_req           (v_req),
      .v_dccm_wen           (v_wen),
      .v_dccm_addr          (v_addr),
      .v_dccm_wdata         (v_wdata),
      .v_dccm_wstrb         (v_wstrb),
      .v_dccm_rdata         (v_rdata),
      .v_dccm_rvalid        (v_rvalid)
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

  logic [XLEN-1:0] lsu_rdata      [LSU_DCCM_PORT_COUNT-1:0];
  logic            lsu_rvalid_out [LSU_DCCM_PORT_COUNT-1:0];
  logic            gemm_rd_hit    [LSU_DCCM_PORT_COUNT-1:0];
  logic            gemm_rd_hit_q  [LSU_DCCM_PORT_COUNT-1:0];
  logic            lsu_rvalid_mem [LSU_DCCM_PORT_COUNT-1:0];

  logic            dram_rd_hit    [LSU_DCCM_PORT_COUNT-1:0];
  logic            dram_rd_hit_q  [LSU_DCCM_PORT_COUNT-1:0];
  logic            dram_wen       [LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dram_rdata     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dram_rvalid    [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_wen_core  [LSU_DCCM_PORT_COUNT-1:0];

  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_lsu_gate
      assign gemm_rd_hit[gp]    = dccm_rvalid_in[gp] && gemm_addr_hit(dccm_raddr[gp]);
      assign dram_rd_hit[gp]    = dccm_rvalid_in[gp] && dram_addr_hit(dccm_raddr[gp]);
      assign dram_wen[gp]       = dccm_wen_mem[gp] && dram_addr_hit(dccm_waddr[gp]);
      assign dccm_wen_core[gp]  = dccm_wen_mem[gp] && !dram_addr_hit(dccm_waddr[gp]);
      assign lsu_rvalid_mem[gp] = dccm_rvalid_in[gp] && !gemm_rd_hit[gp] &&
                                  !dram_rd_hit[gp] && !gemm_busy_w;
    end
  endgenerate

  logic        s_req, s_wen, s_rvalid;
  logic [31:0] s_addr;
  logic [127:0] s_wdata, s_rdata;
  logic [15:0] s_wstrb;

  lsu_dccm_bridge u_lsu_br (
      .clk           (clk),
      .rstn          (rstn),
      .lsu_raddr     (dccm_raddr),
      .lsu_rvalid_in (lsu_rvalid_mem),
      .lsu_rdata     (lsu_rdata),
      .lsu_rvalid_out(lsu_rvalid_out),
      .lsu_waddr     (dccm_waddr),
      .lsu_wen       (dccm_wen_core),
      .lsu_wdata     (dccm_wdata),
      .lsu_wstrb     (dccm_wstrb),
      .dccm_req      (s_req),
      .dccm_wen      (s_wen),
      .dccm_addr     (s_addr),
      .dccm_wdata    (s_wdata),
      .dccm_wstrb    (s_wstrb),
      .dccm_rdata    (s_rdata),
      .dccm_rvalid   (s_rvalid)
  );

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
      for (int unsigned p = 0; p < LSU_DCCM_PORT_COUNT; p++) begin
        gemm_rd_hit_q[p] <= 1'b0;
        dram_rd_hit_q[p] <= 1'b0;
      end
    end else begin
      for (int unsigned p = 0; p < LSU_DCCM_PORT_COUNT; p++) begin
        gemm_rd_hit_q[p] <= gemm_rd_hit[p];
        if (dram_rd_hit[p])
          dram_rd_hit_q[p] <= 1'b1;
        else if (dram_rvalid[p])
          dram_rd_hit_q[p] <= 1'b0;
      end
    end
  end

  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_rdata_mux
      assign dccm_rdata[gp]      = gemm_rd_hit_q[gp] ? gemm_rdata :
                                   (dram_rd_hit_q[gp] ? dram_rdata[gp] : lsu_rdata[gp]);
      assign dccm_rvalid_out[gp] = gemm_rd_hit_q[gp] ? gemm_rvalid :
                                   (dram_rd_hit_q[gp] ? dram_rvalid[gp] : lsu_rvalid_out[gp]);
    end
  endgenerate

  /* LSU → AXI DRAM stub (GEMM stays on DCCM). */
  logic [   AXI_ID_WIDTH-1:0] d0_arid, d1_arid;
  logic [ AXI_ADDR_WIDTH-1:0] d0_araddr, d1_araddr;
  logic [   AXI_LEN_WIDTH-1:0] d0_arlen, d1_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] d0_arsize, d1_arsize;
  logic [ AXI_BURST_WIDTH-1:0] d0_arburst, d1_arburst;
  logic                        d0_arvalid, d1_arvalid, d0_arready, d1_arready;
  logic [   AXI_ID_WIDTH-1:0] d0_rid, d1_rid;
  logic [AXI_DATA_WIDTH-1:0]  d0_rdata, d1_rdata;
  logic [ AXI_RESP_WIDTH-1:0] d0_rresp, d1_rresp;
  logic                        d0_rlast, d1_rlast, d0_rvalid, d1_rvalid, d0_rready, d1_rready;
  logic [   AXI_ID_WIDTH-1:0] d0_awid, d1_awid;
  logic [ AXI_ADDR_WIDTH-1:0] d0_awaddr, d1_awaddr;
  logic [   AXI_LEN_WIDTH-1:0] d0_awlen, d1_awlen;
  logic [  AXI_SIZE_WIDTH-1:0] d0_awsize, d1_awsize;
  logic [ AXI_BURST_WIDTH-1:0] d0_awburst, d1_awburst;
  logic                        d0_awvalid, d1_awvalid, d0_awready, d1_awready;
  logic [AXI_DATA_WIDTH-1:0]  d0_wdata, d1_wdata;
  logic [AXI_STRB_WIDTH-1:0]  d0_wstrb, d1_wstrb;
  logic                        d0_wlast, d1_wlast, d0_wvalid, d1_wvalid, d0_wready, d1_wready;
  logic [   AXI_ID_WIDTH-1:0] d0_bid, d1_bid;
  logic [ AXI_RESP_WIDTH-1:0] d0_bresp, d1_bresp;
  logic                        d0_bvalid, d1_bvalid, d0_bready, d1_bready;

  dmem_to_axi4 u_dram0 (
      .clk            (clk),
      .rstn           (rstn),
      .dccm_raddr     (dccm_raddr[0]),
      .dccm_rvalid_in (dram_rd_hit[0]),
      .dccm_rdata     (dram_rdata[0]),
      .dccm_rvalid_out(dram_rvalid[0]),
      .dccm_waddr     (dccm_waddr[0]),
      .dccm_wen       (dram_wen[0]),
      .dccm_wdata     (dccm_wdata[0]),
      .dccm_wstrb     (dccm_wstrb[0]),
      .m_axi_arid     (d0_arid),
      .m_axi_araddr   (d0_araddr),
      .m_axi_arlen    (d0_arlen),
      .m_axi_arsize   (d0_arsize),
      .m_axi_arburst  (d0_arburst),
      .m_axi_arvalid  (d0_arvalid),
      .m_axi_arready  (d0_arready),
      .m_axi_rid      (d0_rid),
      .m_axi_rdata    (d0_rdata),
      .m_axi_rresp    (d0_rresp),
      .m_axi_rlast    (d0_rlast),
      .m_axi_rvalid   (d0_rvalid),
      .m_axi_rready   (d0_rready),
      .m_axi_awid     (d0_awid),
      .m_axi_awaddr   (d0_awaddr),
      .m_axi_awlen    (d0_awlen),
      .m_axi_awsize   (d0_awsize),
      .m_axi_awburst  (d0_awburst),
      .m_axi_awvalid  (d0_awvalid),
      .m_axi_awready  (d0_awready),
      .m_axi_wdata    (d0_wdata),
      .m_axi_wstrb    (d0_wstrb),
      .m_axi_wlast    (d0_wlast),
      .m_axi_wvalid   (d0_wvalid),
      .m_axi_wready   (d0_wready),
      .m_axi_bid      (d0_bid),
      .m_axi_bresp    (d0_bresp),
      .m_axi_bvalid   (d0_bvalid),
      .m_axi_bready   (d0_bready)
  );

  dmem_to_axi4 u_dram1 (
      .clk            (clk),
      .rstn           (rstn),
      .dccm_raddr     (dccm_raddr[1]),
      .dccm_rvalid_in (dram_rd_hit[1]),
      .dccm_rdata     (dram_rdata[1]),
      .dccm_rvalid_out(dram_rvalid[1]),
      .dccm_waddr     (dccm_waddr[1]),
      .dccm_wen       (dram_wen[1]),
      .dccm_wdata     (dccm_wdata[1]),
      .dccm_wstrb     (dccm_wstrb[1]),
      .m_axi_arid     (d1_arid),
      .m_axi_araddr   (d1_araddr),
      .m_axi_arlen    (d1_arlen),
      .m_axi_arsize   (d1_arsize),
      .m_axi_arburst  (d1_arburst),
      .m_axi_arvalid  (d1_arvalid),
      .m_axi_arready  (d1_arready),
      .m_axi_rid      (d1_rid),
      .m_axi_rdata    (d1_rdata),
      .m_axi_rresp    (d1_rresp),
      .m_axi_rlast    (d1_rlast),
      .m_axi_rvalid   (d1_rvalid),
      .m_axi_rready   (d1_rready),
      .m_axi_awid     (d1_awid),
      .m_axi_awaddr   (d1_awaddr),
      .m_axi_awlen    (d1_awlen),
      .m_axi_awsize   (d1_awsize),
      .m_axi_awburst  (d1_awburst),
      .m_axi_awvalid  (d1_awvalid),
      .m_axi_awready  (d1_awready),
      .m_axi_wdata    (d1_wdata),
      .m_axi_wstrb    (d1_wstrb),
      .m_axi_wlast    (d1_wlast),
      .m_axi_wvalid   (d1_wvalid),
      .m_axi_wready   (d1_wready),
      .m_axi_bid      (d1_bid),
      .m_axi_bresp    (d1_bresp),
      .m_axi_bvalid   (d1_bvalid),
      .m_axi_bready   (d1_bready)
  );

  axi4_dram #(
      .DEPTH(DRAM_BYTES / 4),
      .BASE(DRAM_BASE),
      .INIT_FILE(DRAM_INIT_FILE)
  ) u_dram (
      .clk          (clk),
      .rstn         (rstn),
      .s0_axi_arid  (d0_arid),
      .s0_axi_araddr(d0_araddr),
      .s0_axi_arlen (d0_arlen),
      .s0_axi_arsize(d0_arsize),
      .s0_axi_arburst(d0_arburst),
      .s0_axi_arvalid(d0_arvalid),
      .s0_axi_arready(d0_arready),
      .s0_axi_rid   (d0_rid),
      .s0_axi_rdata (d0_rdata),
      .s0_axi_rresp (d0_rresp),
      .s0_axi_rlast (d0_rlast),
      .s0_axi_rvalid(d0_rvalid),
      .s0_axi_rready(d0_rready),
      .s0_axi_awid  (d0_awid),
      .s0_axi_awaddr(d0_awaddr),
      .s0_axi_awlen (d0_awlen),
      .s0_axi_awsize(d0_awsize),
      .s0_axi_awburst(d0_awburst),
      .s0_axi_awvalid(d0_awvalid),
      .s0_axi_awready(d0_awready),
      .s0_axi_wdata (d0_wdata),
      .s0_axi_wstrb (d0_wstrb),
      .s0_axi_wlast (d0_wlast),
      .s0_axi_wvalid(d0_wvalid),
      .s0_axi_wready(d0_wready),
      .s0_axi_bid   (d0_bid),
      .s0_axi_bresp (d0_bresp),
      .s0_axi_bvalid(d0_bvalid),
      .s0_axi_bready(d0_bready),
      .s1_axi_arid  (d1_arid),
      .s1_axi_araddr(d1_araddr),
      .s1_axi_arlen (d1_arlen),
      .s1_axi_arsize(d1_arsize),
      .s1_axi_arburst(d1_arburst),
      .s1_axi_arvalid(d1_arvalid),
      .s1_axi_arready(d1_arready),
      .s1_axi_rid   (d1_rid),
      .s1_axi_rdata (d1_rdata),
      .s1_axi_rresp (d1_rresp),
      .s1_axi_rlast (d1_rlast),
      .s1_axi_rvalid(d1_rvalid),
      .s1_axi_rready(d1_rready),
      .s1_axi_awid  (d1_awid),
      .s1_axi_awaddr(d1_awaddr),
      .s1_axi_awlen (d1_awlen),
      .s1_axi_awsize(d1_awsize),
      .s1_axi_awburst(d1_awburst),
      .s1_axi_awvalid(d1_awvalid),
      .s1_axi_awready(d1_awready),
      .s1_axi_wdata (d1_wdata),
      .s1_axi_wstrb (d1_wstrb),
      .s1_axi_wlast (d1_wlast),
      .s1_axi_wvalid(d1_wvalid),
      .s1_axi_wready(d1_wready),
      .s1_axi_bid   (d1_bid),
      .s1_axi_bresp (d1_bresp),
      .s1_axi_bvalid(d1_bvalid),
      .s1_axi_bready(d1_bready),
      .host_en      (1'b0),
      .host_wr      (1'b0),
      .host_addr    (32'd0),
      .host_din     (32'd0),
      .host_wstrb   (4'd0),
      .host_dout    (),
      .host_rvalid  ()
  );

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

  logic        g_req, g_wen, g_rvalid;
  logic [31:0] g_addr;
  logic [127:0] g_wdata, g_rdata;
  logic [15:0] g_wstrb;

  gemm_dccm_pair u_gemm_mem (
      .clk          (clk),
      .rstn         (rstn),
      .s0_axi_arid  (g0_arid),
      .s0_axi_araddr(g0_araddr),
      .s0_axi_arlen (g0_arlen),
      .s0_axi_arsize(g0_arsize),
      .s0_axi_arburst(g0_arburst),
      .s0_axi_arvalid(g0_arvalid),
      .s0_axi_arready(g0_arready),
      .s0_axi_rid   (g0_rid),
      .s0_axi_rdata (g0_rdata),
      .s0_axi_rresp (g0_rresp),
      .s0_axi_rlast (g0_rlast),
      .s0_axi_rvalid(g0_rvalid),
      .s0_axi_rready(g0_rready),
      .s0_axi_awid  (g0_awid),
      .s0_axi_awaddr(g0_awaddr),
      .s0_axi_awlen (g0_awlen),
      .s0_axi_awsize(g0_awsize),
      .s0_axi_awburst(g0_awburst),
      .s0_axi_awvalid(g0_awvalid),
      .s0_axi_awready(g0_awready),
      .s0_axi_wdata (g0_wdata),
      .s0_axi_wstrb (g0_wstrb),
      .s0_axi_wlast (g0_wlast),
      .s0_axi_wvalid(g0_wvalid),
      .s0_axi_wready(g0_wready),
      .s0_axi_bid   (g0_bid),
      .s0_axi_bresp (g0_bresp),
      .s0_axi_bvalid(g0_bvalid),
      .s0_axi_bready(g0_bready),
      .s1_axi_arid  (g1_arid),
      .s1_axi_araddr(g1_araddr),
      .s1_axi_arlen (g1_arlen),
      .s1_axi_arsize(g1_arsize),
      .s1_axi_arburst(g1_arburst),
      .s1_axi_arvalid(g1_arvalid),
      .s1_axi_arready(g1_arready),
      .s1_axi_rid   (g1_rid),
      .s1_axi_rdata (g1_rdata),
      .s1_axi_rresp (g1_rresp),
      .s1_axi_rlast (g1_rlast),
      .s1_axi_rvalid(g1_rvalid),
      .s1_axi_rready(g1_rready),
      .s1_axi_awid  (g1_awid),
      .s1_axi_awaddr(g1_awaddr),
      .s1_axi_awlen (g1_awlen),
      .s1_axi_awsize(g1_awsize),
      .s1_axi_awburst(g1_awburst),
      .s1_axi_awvalid(g1_awvalid),
      .s1_axi_awready(g1_awready),
      .s1_axi_wdata (g1_wdata),
      .s1_axi_wstrb (g1_wstrb),
      .s1_axi_wlast (g1_wlast),
      .s1_axi_wvalid(g1_wvalid),
      .s1_axi_wready(g1_wready),
      .s1_axi_bid   (g1_bid),
      .s1_axi_bresp (g1_bresp),
      .s1_axi_bvalid(g1_bvalid),
      .s1_axi_bready(g1_bready),
      .dccm_req     (g_req),
      .dccm_wen     (g_wen),
      .dccm_addr    (g_addr),
      .dccm_wdata   (g_wdata),
      .dccm_wstrb   (g_wstrb),
      .dccm_rdata   (g_rdata),
      .dccm_rvalid  (g_rvalid)
  );

  soc_dccm #(
      .DEPTH(DATA_MEM_DEPTH),
      .WIDTH(DATA_MEM_WIDTH),
      .INIT_FILE(DCCM_INIT_FILE)
  ) u_dccm (
      .clk        (clk),
      .rstn       (rstn),
      .s_req      (s_req && !gemm_busy_w),
      .s_wen      (s_wen),
      .s_addr     (s_addr),
      .s_wdata    (s_wdata),
      .s_wstrb    (s_wstrb),
      .s_rdata    (s_rdata),
      .s_rvalid   (s_rvalid),
      .v_req      (v_req && !gemm_busy_w),
      .v_wen      (v_wen),
      .v_addr     (v_addr),
      .v_wdata    (v_wdata),
      .v_wstrb    (v_wstrb),
      .v_rdata    (v_rdata),
      .v_rvalid   (v_rvalid),
      .g_req      (g_req),
      .g_wen      (g_wen),
      .g_addr     (g_addr),
      .g_wdata    (g_wdata),
      .g_wstrb    (g_wstrb),
      .g_rdata    (g_rdata),
      .g_rvalid   (g_rvalid),
      .host_sel   (1'b0),
      .host_en    (1'b0),
      .host_wr    (1'b0),
      .host_addr  (32'd0),
      .host_din   (32'd0),
      .host_wstrb (4'd0),
      .host_dout  (),
      .host_rvalid()
  );

  logic unused_axil = &{1'b0, gemm_awready, gemm_wready, gemm_bresp, gemm_bvalid, gemm_arready,
                        gemm_rresp};

endmodule
