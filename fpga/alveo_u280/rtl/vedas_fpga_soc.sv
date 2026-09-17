///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Tiny-Vedas FPGA SoC (Slice B):
//   AXI + CTRL + UART/EOT @ s_axi_aclk (~250 MHz)
//   core + ICCM/DCCM @ core_clk (100 MHz)
//
//   Memories are single-clock on core_clk. Host ICCM/DCCM: req/ack CDC
//   (halt-and-load) via AXI4 slave host ports with byte strobes (no RMW).
//   Core fetch/LSU go through imem_to_axi4 / dmem_to_axi4.
//   BAR2: CTRL@0x0 (4KiB), ICCM@0x1000 (32KiB), DCCM@0x9000 (1MiB).
//   Pass criterion: EOT (+ optional UART golden). No retire TRACE on FPGA.
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

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

module vedas_fpga_soc #(
    parameter logic [31:0] VERSION = 32'h000B_0012,
    parameter int UART_FIFO_DEPTH = 256,
    parameter logic [XLEN-1:0] STACK_POINTER_INIT_VALUE = 32'h8000_0000
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire        core_clk,
    input  wire        core_clk_locked,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire [15:0] gemm_ila
);

  localparam logic [31:0] CTRL_BASE = 32'h0000_0000;
  localparam logic [31:0] CTRL_END  = 32'h0000_1000;
  localparam logic [31:0] ICCM_BASE = 32'h0000_1000;
  localparam logic [31:0] ICCM_END  = 32'h0000_9000;
  localparam logic [31:0] DCCM_BASE = 32'h0000_9000;
  localparam logic [31:0] DCCM_END  = 32'h0010_9000;

  localparam int ICCM_AW = $clog2(INSTR_MEM_DEPTH);
  localparam int DCCM_AW = $clog2(DATA_MEM_DEPTH);
  localparam int UART_AW = $clog2(UART_FIFO_DEPTH);

  wire [31:0] aw_addr = s_axi_awaddr;
  wire [31:0] ar_addr = s_axi_araddr;

  wire aw_ctrl = (aw_addr >= CTRL_BASE) && (aw_addr < CTRL_END);
  wire aw_iccm = (aw_addr >= ICCM_BASE) && (aw_addr < ICCM_END);
  wire aw_dccm = (aw_addr >= DCCM_BASE) && (aw_addr < DCCM_END);
  wire ar_ctrl = (ar_addr >= CTRL_BASE) && (ar_addr < CTRL_END);
  wire ar_iccm = (ar_addr >= ICCM_BASE) && (ar_addr < ICCM_END);
  wire ar_dccm = (ar_addr >= DCCM_BASE) && (ar_addr < DCCM_END);

  // ----- AXI CTRL -----
  reg [31:0] scratch;
  reg [31:0] heartbeat;
  reg        core_run;
  reg [31:0] reset_vector_r;
  reg        eot_clear_a;
  reg        uart_clear_a;
  reg [3:0]  uart_clear_hold;

  wire host_mem_ok = ~core_run;

  reg [7:0]        uart_mem[UART_FIFO_DEPTH];
  reg [UART_AW:0]  uart_wr_ptr;
  reg [UART_AW:0]  uart_rd_ptr;
  wire [UART_AW:0] uart_level = uart_wr_ptr - uart_rd_ptr;
  wire             uart_empty = (uart_wr_ptr == uart_rd_ptr);
  wire             uart_full  = (uart_level == UART_FIFO_DEPTH[UART_AW:0]);

  // ----- CDC: control / UART / EOT -----
  wire        core_run_c;
  wire        axi_rstn_c;
  wire [31:0] reset_vector_c;
  wire        eot_clear_c;
  wire        uart_clear_c;
  wire        eot_done_c;
  wire        eot_done_a;

  reg         uart_req_c;
  reg  [7:0]  uart_data_c;
  reg         uart_busy_c;
  reg         uart_ack_a;
  wire        uart_req_a;
  wire [7:0]  uart_data_a;
  wire        uart_ack_c;

  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_run    (.clk(core_clk),   .din(core_run),                        .dout(core_run_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_arstn  (.clk(core_clk),   .din(s_axi_aresetn & core_clk_locked), .dout(axi_rstn_c));
  cdc_sync #(.N(3), .WIDTH(32)) u_cdc_rstvec (.clk(core_clk),   .din(reset_vector_r),                  .dout(reset_vector_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_eotclr (.clk(core_clk),   .din(eot_clear_a),                     .dout(eot_clear_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_uclr   (.clk(core_clk),   .din(uart_clear_a),                    .dout(uart_clear_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_eot    (.clk(s_axi_aclk), .din(eot_done_c),                      .dout(eot_done_a));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_ureq   (.clk(s_axi_aclk), .din(uart_req_c),                      .dout(uart_req_a));
  cdc_sync #(.N(3), .WIDTH(8))  u_cdc_udata  (.clk(s_axi_aclk), .din(uart_data_c),                     .dout(uart_data_a));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_uack   (.clk(core_clk),   .din(uart_ack_a),                      .dout(uart_ack_c));

  wire core_rstn = axi_rstn_c & core_run_c;

  // ----- Host mem CDC -----
  reg         host_req_a;
  reg         host_ack_a_q;
  reg         host_wr_a;
  reg         host_iccm_a;
  reg [31:0]  host_addr_a;
  reg [31:0]  host_wdata_a;
  reg [3:0]   host_wstrb_a;
  reg         host_busy_a;
  reg         host_is_write_a;

  wire        host_req_c;
  wire        host_wr_c;
  wire        host_iccm_c;
  wire [31:0] host_addr_c;
  wire [31:0] host_wdata_c;
  wire [3:0]  host_wstrb_c;
  reg         host_ack_c;
  reg [31:0]  host_rdata_c;
  wire        host_ack_a;
  wire [31:0] host_rdata_a;

  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_hreq  (.clk(core_clk),   .din(host_req_a),   .dout(host_req_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_hwr   (.clk(core_clk),   .din(host_wr_a),    .dout(host_wr_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_hiccm (.clk(core_clk),   .din(host_iccm_a),  .dout(host_iccm_c));
  cdc_sync #(.N(3), .WIDTH(32)) u_cdc_haddr (.clk(core_clk),   .din(host_addr_a),  .dout(host_addr_c));
  cdc_sync #(.N(3), .WIDTH(32)) u_cdc_hwdat (.clk(core_clk),   .din(host_wdata_a), .dout(host_wdata_c));
  cdc_sync #(.N(3), .WIDTH(4))  u_cdc_hstrb (.clk(core_clk),   .din(host_wstrb_a), .dout(host_wstrb_c));
  cdc_sync #(.N(3), .WIDTH(1))  u_cdc_hack  (.clk(s_axi_aclk), .din(host_ack_c),   .dout(host_ack_a));
  cdc_sync #(.N(3), .WIDTH(32)) u_cdc_hrdat (.clk(s_axi_aclk), .din(host_rdata_c), .dout(host_rdata_a));

  // =========================================================================
  // ICCM / DCCM via AXI4 adapters. Host halt-and-load uses byte strobes (no RMW).
  // =========================================================================
  logic [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr;
  logic                            instr_mem_addr_valid;
  logic [INSTR_MEM_TAG_WIDTH-1:0]  instr_mem_tag_out;
  logic [INSTR_MEM_WIDTH-1:0]      instr_mem_rdata;
  logic                            instr_mem_rdata_valid;
  logic [INSTR_MEM_TAG_WIDTH-1:0]  instr_mem_tag_in;

  typedef enum logic [1:0] {
    H_IDLE    = 2'd0,
    H_ICCM_RD = 2'd1,
    H_DCCM_RD = 2'd2
  } host_mem_state_e;

  host_mem_state_e host_st;
  reg              host_req_c_q;
  wire             host_req_edge = host_req_c ^ host_req_c_q;

  wire [ICCM_AW-1:0] host_iccm_widx = host_addr_c[ICCM_AW-1:0];
  wire [DCCM_AW-1:0] host_dccm_idx = host_addr_c[DCCM_AW-1:0];

  wire host_iccm_we = (host_st == H_IDLE) && host_req_edge && !core_run_c &&
                      host_wr_c && host_iccm_c;
  wire host_iccm_re = (host_st == H_IDLE) && host_req_edge && !core_run_c &&
                      !host_wr_c && host_iccm_c;
  wire host_dccm_we = (host_st == H_IDLE) && host_req_edge && !core_run_c &&
                      host_wr_c && !host_iccm_c;
  wire host_dccm_re = (host_st == H_IDLE) && host_req_edge && !core_run_c &&
                      !host_wr_c && !host_iccm_c;

  logic [INSTR_MEM_ADDR_WIDTH-1:0] host_iccm_raddr;
  logic [INSTR_MEM_WIDTH-1:0]      host_iccm_rdata;
  logic                            host_iccm_rvalid;
  assign host_iccm_raddr = {{(INSTR_MEM_ADDR_WIDTH - ICCM_AW - 2){1'b0}}, host_iccm_widx, 2'b00};

  logic [XLEN-1:0] dccm_raddr     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_rvalid_in [LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dccm_rdata     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_rvalid_out[LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dccm_waddr     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_wen       [LSU_DCCM_PORT_COUNT-1:0];
  logic [XLEN-1:0] dccm_wdata     [LSU_DCCM_PORT_COUNT-1:0];
  logic [     3:0] dccm_wstrb     [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_wen_hit   [LSU_DCCM_PORT_COUNT-1:0];
  logic            dccm_wen_mem   [LSU_DCCM_PORT_COUNT-1:0];
  logic            mmio_dev_we    [MMIO_DEV_COUNT-1:0];
  logic [XLEN-1:0] mmio_dev_addr  [MMIO_DEV_COUNT-1:0];
  logic [XLEN-1:0] mmio_dev_wdata [MMIO_DEV_COUNT-1:0];

  mmio_mux u_mmio (
      .addr     (dccm_waddr),
      .wen      (dccm_wen),
      .wdata    (dccm_wdata),
      .mem_wen  (dccm_wen_hit),
      .dev_we   (mmio_dev_we),
      .dev_addr (mmio_dev_addr),
      .dev_wdata(mmio_dev_wdata)
  );

  wire dccm_is_uart = mmio_dev_we[MMIO_IDX_UART];
  wire dccm_is_eot  = mmio_dev_we[MMIO_IDX_EOT] &&
                      (mmio_dev_wdata[MMIO_IDX_EOT] == EOT_MAGIC);
  wire [7:0] dccm_uart_byte = mmio_dev_wdata[MMIO_IDX_UART][7:0];

  genvar gp;
  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_mmio
      assign dccm_wen_mem[gp] = dccm_wen_hit[gp] && core_rstn;
    end
  endgenerate

  logic [31:0] host_dccm_dout;
  logic        host_dccm_rvalid;

  logic [   AXI_ID_WIDTH-1:0] imem_arid;
  logic [ AXI_ADDR_WIDTH-1:0] imem_araddr;
  logic [   AXI_LEN_WIDTH-1:0] imem_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] imem_arsize;
  logic [ AXI_BURST_WIDTH-1:0] imem_arburst;
  logic                        imem_arvalid, imem_arready;
  logic [   AXI_ID_WIDTH-1:0] imem_rid;
  logic [AXI_DATA_WIDTH-1:0]  imem_rdata_axi;
  logic [ AXI_RESP_WIDTH-1:0] imem_rresp;
  logic                        imem_rlast, imem_rvalid, imem_rready;

  imem_to_axi4 u_imem_ad (
      .clk                  (core_clk),
      .rstn                 (core_rstn),
      .instr_mem_addr       (instr_mem_addr),
      .instr_mem_addr_valid (instr_mem_addr_valid & core_rstn),
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
      .m_axi_rdata          (imem_rdata_axi),
      .m_axi_rresp          (imem_rresp),
      .m_axi_rlast          (imem_rlast),
      .m_axi_rvalid         (imem_rvalid),
      .m_axi_rready         (imem_rready)
  );

  axi4_iccm #(
      .DEPTH(INSTR_MEM_DEPTH),
      .WIDTH(INSTR_MEM_WIDTH),
      .INIT_FILE("")
  ) u_iccm (
      .clk          (core_clk),
      .rstn         (axi_rstn_c),
      .s_axi_arid   (imem_arid),
      .s_axi_araddr (imem_araddr),
      .s_axi_arlen  (imem_arlen),
      .s_axi_arsize (imem_arsize),
      .s_axi_arburst(imem_arburst),
      .s_axi_arvalid(imem_arvalid),
      .s_axi_arready(imem_arready),
      .s_axi_rid    (imem_rid),
      .s_axi_rdata  (imem_rdata_axi),
      .s_axi_rresp  (imem_rresp),
      .s_axi_rlast  (imem_rlast),
      .s_axi_rvalid (imem_rvalid),
      .s_axi_rready (imem_rready),
      .host_wen     (host_iccm_we),
      .host_waddr   (host_iccm_widx),
      .host_wdata   (host_wdata_c),
      .host_wstrb   (host_wstrb_c),
      .host_ren     (host_iccm_re || (host_st == H_ICCM_RD)),
      .host_raddr   (host_iccm_raddr),
      .host_rdata   (host_iccm_rdata),
      .host_rvalid  (host_iccm_rvalid)
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
  logic            accel_hold_w;
  logic            gemm_busy_w;
  logic            gemm_pe_valid;
  logic            gemm_dma_arvalid, gemm_dma_awvalid, gemm_status_done;

  function automatic logic gemm_addr_hit(input logic [31:0] a);
    return (a >= MMIO_GEMM_ADDR) && (a < (MMIO_GEMM_ADDR + MMIO_GEMM_SIZE));
  endfunction

  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_dmem_ad
      assign gemm_rd_hit[gp] = dccm_rvalid_in[gp] && gemm_addr_hit(dccm_raddr[gp]);
      dmem_to_axi4 u_dmem_ad (
          .clk            (core_clk),
          .rstn           (core_rstn),
          .dccm_raddr     (dccm_raddr[gp]),
          .dccm_rvalid_in (dccm_rvalid_in[gp] & core_rstn & !gemm_rd_hit[gp] & !gemm_busy_w),
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

  always_ff @(posedge core_clk) begin
    if (!axi_rstn_c) begin
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
      .clk            (core_clk),
      .rstn           (core_rstn),
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
      .pe_valid       (gemm_pe_valid),
      .dma_arvalid    (gemm_dma_arvalid),
      .dma_awvalid    (gemm_dma_awvalid),
      .status_done    (gemm_status_done),
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

  assign gemm_ila = {
      4'd0,
      gemm_awvalid,
      gemm_wvalid,
      g0_arready,
      g0_awready,
      gemm_status_done,
      gemm_pe_valid,
      gemm_dma_awvalid,
      gemm_dma_arvalid,
      accel_hold_w,
      gemm_busy_w
  };

  axi4_dccm #(
      .DEPTH(DATA_MEM_DEPTH),
      .WIDTH(DATA_MEM_WIDTH),
      .INIT_FILE("")
  ) u_dccm (
      .clk          (core_clk),
      .rstn         (axi_rstn_c),
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
      .host_sel     (!core_run_c),
      .host_en      (host_dccm_we || host_dccm_re || (host_st == H_DCCM_RD)),
      .host_wr      (host_dccm_we),
      .host_addr    (host_dccm_idx),
      .host_din     (host_wdata_c),
      .host_wstrb   (host_wstrb_c),
      .host_dout    (host_dccm_dout),
      .host_rvalid  (host_dccm_rvalid)
  );

  always_ff @(posedge core_clk) begin
    if (!axi_rstn_c) begin
      host_st      <= H_IDLE;
      host_req_c_q <= 1'b0;
      host_ack_c   <= 1'b0;
      host_rdata_c <= 32'h0;
    end else begin
      host_req_c_q <= host_req_c;
      unique case (host_st)
        H_IDLE: begin
          if (host_req_edge && !core_run_c) begin
            if (host_iccm_c) begin
              if (host_wr_c) host_ack_c <= ~host_ack_c;
              else           host_st <= H_ICCM_RD;
            end else begin
              if (host_wr_c) host_ack_c <= ~host_ack_c;
              else           host_st <= H_DCCM_RD;
            end
          end
        end
        H_ICCM_RD: begin
          if (host_iccm_rvalid) begin
            host_rdata_c <= host_iccm_rdata;
            host_ack_c   <= ~host_ack_c;
            host_st      <= H_IDLE;
          end
        end
        H_DCCM_RD: begin
          if (host_dccm_rvalid) begin
            host_rdata_c <= host_dccm_dout;
            host_ack_c   <= ~host_ack_c;
            host_st      <= H_IDLE;
          end
        end
        default: host_st <= H_IDLE;
      endcase
    end
  end

  // EOT sticky (core)
  reg eot_done_c_r;
  assign eot_done_c = eot_done_c_r;
  always_ff @(posedge core_clk) begin
    if (!axi_rstn_c)       eot_done_c_r <= 1'b0;
    else if (eot_clear_c)  eot_done_c_r <= 1'b0;
    else if (dccm_is_eot && core_rstn) eot_done_c_r <= 1'b1;
  end

  // UART core side
  reg uart_ack_c_q;
  always_ff @(posedge core_clk) begin
    if (!axi_rstn_c) begin
      uart_req_c   <= 1'b0;
      uart_busy_c  <= 1'b0;
      uart_data_c  <= 8'h0;
      uart_ack_c_q <= 1'b0;
    end else begin
      uart_ack_c_q <= uart_ack_c;
      if (uart_clear_c)
        uart_busy_c <= 1'b0;
      else if (uart_busy_c && (uart_ack_c ^ uart_ack_c_q))
        uart_busy_c <= 1'b0;
      else if (dccm_is_uart && core_rstn && !uart_busy_c) begin
        uart_data_c <= dccm_uart_byte;
        uart_req_c  <= ~uart_req_c;
        uart_busy_c <= 1'b1;
      end
    end
  end

  core_top #(.STACK_POINTER_INIT_VALUE(STACK_POINTER_INIT_VALUE)) core_i (
      .clk(core_clk), .rstn(core_rstn), .reset_vector(reset_vector_c),
      .instr_mem_addr(instr_mem_addr), .instr_mem_addr_valid(instr_mem_addr_valid),
      .instr_mem_tag_out(instr_mem_tag_out), .instr_mem_rdata(instr_mem_rdata),
      .instr_mem_rdata_valid(instr_mem_rdata_valid), .instr_mem_tag_in(instr_mem_tag_in),
      .dccm_raddr(dccm_raddr), .dccm_rvalid_in(dccm_rvalid_in), .dccm_rdata(dccm_rdata),
      .dccm_rvalid_out(dccm_rvalid_out), .dccm_waddr(dccm_waddr), .dccm_wen(dccm_wen),
      .dccm_wdata(dccm_wdata), .dccm_wstrb(dccm_wstrb),
      .accel_hold(accel_hold_w)
  );

  // ----- AXI-Lite -----
  wire aw_hs = s_axi_awvalid & s_axi_awready;
  wire w_hs  = s_axi_wvalid & s_axi_wready;
  wire ar_hs = s_axi_arvalid & s_axi_arready;
  wire write_en = aw_hs & w_hs;

  assign s_axi_awready = s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid & ~host_busy_a;
  assign s_axi_wready  = s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid & ~host_busy_a;
  assign s_axi_arready = s_axi_arvalid & ~s_axi_rvalid & ~host_busy_a;

  wire [ICCM_AW-1:0] axi_iccm_widx = ICCM_AW'( (aw_addr - ICCM_BASE) >> 2 );
  wire [DCCM_AW-1:0] axi_dccm_widx = DCCM_AW'( (aw_addr - DCCM_BASE) >> 2 );
  wire [ICCM_AW-1:0] axi_iccm_ridx = ICCM_AW'( (ar_addr - ICCM_BASE) >> 2 );
  wire [DCCM_AW-1:0] axi_dccm_ridx = DCCM_AW'( (ar_addr - DCCM_BASE) >> 2 );

  reg uart_req_a_q;
  wire host_ack_edge = host_ack_a ^ host_ack_a_q;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      scratch         <= 32'h0;
      heartbeat       <= 32'h0;
      core_run        <= 1'b0;
      reset_vector_r  <= 32'h0010_0000;
      eot_clear_a     <= 1'b0;
      uart_clear_a    <= 1'b0;
      uart_clear_hold <= 4'h0;
      uart_wr_ptr     <= '0;
      uart_rd_ptr     <= '0;
      uart_ack_a      <= 1'b0;
      uart_req_a_q    <= 1'b0;
      host_req_a      <= 1'b0;
      host_ack_a_q    <= 1'b0;
      host_wr_a       <= 1'b0;
      host_iccm_a     <= 1'b0;
      host_addr_a     <= 32'h0;
      host_wdata_a    <= 32'h0;
      host_wstrb_a    <= 4'h0;
      host_busy_a     <= 1'b0;
      host_is_write_a <= 1'b0;
      s_axi_bvalid    <= 1'b0;
      s_axi_bresp     <= 2'b00;
      s_axi_rvalid    <= 1'b0;
      s_axi_rresp     <= 2'b00;
      s_axi_rdata     <= 32'h0;
    end else begin
      heartbeat    <= heartbeat + 32'h1;
      uart_req_a_q <= uart_req_a;
      host_ack_a_q <= host_ack_a;

      if (eot_clear_a && !eot_done_a)
        eot_clear_a <= 1'b0;

      if (uart_clear_hold != 4'h0) begin
        uart_clear_hold <= uart_clear_hold - 4'h1;
        if (uart_clear_hold == 4'h1)
          uart_clear_a <= 1'b0;
      end

      // Always complete the handshake. If FIFO is full, drop the byte but still
      // ack — otherwise core uart_busy sticks forever.
      if (uart_req_a ^ uart_req_a_q) begin
        if (!uart_full) begin
          uart_mem[uart_wr_ptr[UART_AW-1:0]] <= uart_data_a;
          uart_wr_ptr <= uart_wr_ptr + 1'b1;
        end
        uart_ack_a <= ~uart_ack_a;
      end

      if (host_busy_a && host_ack_edge) begin
        host_busy_a <= 1'b0;
        if (host_is_write_a) begin
          s_axi_bvalid <= 1'b1;
          s_axi_bresp  <= 2'b00;
        end else begin
          s_axi_rvalid <= 1'b1;
          s_axi_rresp  <= 2'b00;
          s_axi_rdata  <= host_rdata_a;
        end
      end

      if (write_en) begin
        if (aw_ctrl) begin
          s_axi_bvalid <= 1'b1;
          s_axi_bresp  <= 2'b00;
          unique case (aw_addr[7:0])
            8'h04: begin
              if (s_axi_wstrb[0]) scratch[7:0]   <= s_axi_wdata[7:0];
              if (s_axi_wstrb[1]) scratch[15:8]  <= s_axi_wdata[15:8];
              if (s_axi_wstrb[2]) scratch[23:16] <= s_axi_wdata[23:16];
              if (s_axi_wstrb[3]) scratch[31:24] <= s_axi_wdata[31:24];
            end
            8'h0C: core_run <= s_axi_wdata[0];
            8'h10: begin
              if (s_axi_wstrb[0]) reset_vector_r[7:0]   <= s_axi_wdata[7:0];
              if (s_axi_wstrb[1]) reset_vector_r[15:8]  <= s_axi_wdata[15:8];
              if (s_axi_wstrb[2]) reset_vector_r[23:16] <= s_axi_wdata[23:16];
              if (s_axi_wstrb[3]) reset_vector_r[31:24] <= s_axi_wdata[31:24];
            end
            8'h18: if (s_axi_wdata[0]) eot_clear_a <= 1'b1;
            8'h24: if (s_axi_wdata[0]) begin
              uart_clear_a    <= 1'b1;
              uart_clear_hold <= 4'hF;
              uart_wr_ptr     <= '0;
              uart_rd_ptr     <= '0;
            end
            default: ;
          endcase
        end else if ((aw_iccm || aw_dccm) && host_mem_ok) begin
          host_wr_a       <= 1'b1;
          host_iccm_a     <= aw_iccm;
          host_addr_a     <= aw_iccm ? { {(32-ICCM_AW){1'b0}}, axi_iccm_widx }
                                     : { {(32-DCCM_AW){1'b0}}, axi_dccm_widx };
          host_wdata_a    <= s_axi_wdata;
          host_wstrb_a    <= s_axi_wstrb;
          host_req_a      <= ~host_req_a;
          host_busy_a     <= 1'b1;
          host_is_write_a <= 1'b1;
        end else begin
          s_axi_bvalid <= 1'b1;
          s_axi_bresp  <= 2'b10;
        end
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (ar_hs) begin
        if (ar_ctrl) begin
          s_axi_rvalid <= 1'b1;
          s_axi_rresp  <= 2'b00;
          unique case (ar_addr[7:0])
            8'h00: s_axi_rdata <= VERSION;
            8'h04: s_axi_rdata <= scratch;
            8'h08: s_axi_rdata <= heartbeat;
            8'h0C: s_axi_rdata <= {30'h0, core_clk_locked, core_run};
            8'h10: s_axi_rdata <= reset_vector_r;
            8'h14: s_axi_rdata <= {31'h0, eot_done_a};
            8'h1C: s_axi_rdata <= {14'h0, uart_full, uart_empty,
                                    {{(16-(UART_AW+1)){1'b0}}, uart_level}};
            8'h20: begin
              if (!uart_empty) begin
                s_axi_rdata <= {24'h0, uart_mem[uart_rd_ptr[UART_AW-1:0]]};
                uart_rd_ptr <= uart_rd_ptr + 1'b1;
              end else s_axi_rdata <= 32'hFFFF_FFFF;
            end
            default: s_axi_rdata <= 32'hDEAD_BEEF;
          endcase
        end else if ((ar_iccm || ar_dccm) && host_mem_ok) begin
          host_wr_a       <= 1'b0;
          host_iccm_a     <= ar_iccm;
          host_addr_a     <= ar_iccm ? { {(32-ICCM_AW){1'b0}}, axi_iccm_ridx }
                                     : { {(32-DCCM_AW){1'b0}}, axi_dccm_ridx };
          host_req_a      <= ~host_req_a;
          host_busy_a     <= 1'b1;
          host_is_write_a <= 1'b0;
        end else begin
          s_axi_rvalid <= 1'b1;
          s_axi_rdata  <= 32'hDEAD_BEEF;
          s_axi_rresp  <= 2'b10;
        end
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

  logic unused_gemm_axil = &{1'b0, gemm_awready, gemm_wready, gemm_bresp, gemm_bvalid,
                             gemm_arready, gemm_rresp};

endmodule
