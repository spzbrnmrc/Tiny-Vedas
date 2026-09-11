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
//   BAR2: CTRL@0x0 (4KiB), ICCM@0x1000 (32KiB), DCCM@0x9000 (64KiB).
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

module vedas_fpga_soc #(
    parameter logic [31:0] VERSION = 32'h000B_0010,
    parameter int UART_FIFO_DEPTH = 256,
    parameter logic [31:0] UART_ADDRESS = 32'h0020_0000,
    parameter logic [31:0] EOT_ADDRESS = 32'h1000_0000,
    parameter logic [31:0] EOT_MAGIC = 32'hDEAD_BEEF,
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
    input  wire        s_axi_rready
);

  localparam logic [31:0] CTRL_BASE = 32'h0000_0000;
  localparam logic [31:0] CTRL_END  = 32'h0000_1000;
  localparam logic [31:0] ICCM_BASE = 32'h0000_1000;
  localparam logic [31:0] ICCM_END  = 32'h0000_9000;
  localparam logic [31:0] DCCM_BASE = 32'h0000_9000;
  localparam logic [31:0] DCCM_END  = 32'h0001_9000;

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

  logic [XLEN-1:0] dccm_raddr, dccm_waddr, dccm_wdata, dccm_rdata;
  logic            dccm_rvalid_in, dccm_rvalid_out, dccm_wen;
  logic [3:0]      dccm_wstrb;
  wire dccm_is_uart = (dccm_waddr == UART_ADDRESS);
  wire dccm_is_eot  = (dccm_waddr == EOT_ADDRESS) && (dccm_wdata == EOT_MAGIC);
  wire dccm_mmio    = dccm_is_uart || (dccm_waddr == EOT_ADDRESS);
  wire dccm_wen_mem = dccm_wen && !dccm_mmio && core_rstn;

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

  logic [   AXI_ID_WIDTH-1:0] dmem_arid, dmem_awid, dmem_rid, dmem_bid;
  logic [ AXI_ADDR_WIDTH-1:0] dmem_araddr, dmem_awaddr;
  logic [   AXI_LEN_WIDTH-1:0] dmem_arlen, dmem_awlen;
  logic [  AXI_SIZE_WIDTH-1:0] dmem_arsize, dmem_awsize;
  logic [ AXI_BURST_WIDTH-1:0] dmem_arburst, dmem_awburst;
  logic                        dmem_arvalid, dmem_arready, dmem_rvalid, dmem_rready, dmem_rlast;
  logic [AXI_DATA_WIDTH-1:0]  dmem_rdata_axi, dmem_wdata_axi;
  logic [ AXI_RESP_WIDTH-1:0] dmem_rresp, dmem_bresp;
  logic                        dmem_awvalid, dmem_awready, dmem_wvalid, dmem_wready, dmem_wlast;
  logic [AXI_STRB_WIDTH-1:0]  dmem_wstrb_axi;
  logic                        dmem_bvalid, dmem_bready;

  dmem_to_axi4 u_dmem_ad (
      .clk            (core_clk),
      .rstn           (core_rstn),
      .dccm_raddr     (dccm_raddr),
      .dccm_rvalid_in (dccm_rvalid_in & core_rstn),
      .dccm_rdata     (dccm_rdata),
      .dccm_rvalid_out(dccm_rvalid_out),
      .dccm_waddr     (dccm_waddr),
      .dccm_wen       (dccm_wen_mem),
      .dccm_wdata     (dccm_wdata),
      .dccm_wstrb     (dccm_wstrb),
      .m_axi_arid     (dmem_arid),
      .m_axi_araddr   (dmem_araddr),
      .m_axi_arlen    (dmem_arlen),
      .m_axi_arsize   (dmem_arsize),
      .m_axi_arburst  (dmem_arburst),
      .m_axi_arvalid  (dmem_arvalid),
      .m_axi_arready  (dmem_arready),
      .m_axi_rid      (dmem_rid),
      .m_axi_rdata    (dmem_rdata_axi),
      .m_axi_rresp    (dmem_rresp),
      .m_axi_rlast    (dmem_rlast),
      .m_axi_rvalid   (dmem_rvalid),
      .m_axi_rready   (dmem_rready),
      .m_axi_awid     (dmem_awid),
      .m_axi_awaddr   (dmem_awaddr),
      .m_axi_awlen    (dmem_awlen),
      .m_axi_awsize   (dmem_awsize),
      .m_axi_awburst  (dmem_awburst),
      .m_axi_awvalid  (dmem_awvalid),
      .m_axi_awready  (dmem_awready),
      .m_axi_wdata    (dmem_wdata_axi),
      .m_axi_wstrb    (dmem_wstrb_axi),
      .m_axi_wlast    (dmem_wlast),
      .m_axi_wvalid   (dmem_wvalid),
      .m_axi_wready   (dmem_wready),
      .m_axi_bid      (dmem_bid),
      .m_axi_bresp    (dmem_bresp),
      .m_axi_bvalid   (dmem_bvalid),
      .m_axi_bready   (dmem_bready)
  );

  axi4_dccm #(
      .DEPTH(DATA_MEM_DEPTH),
      .WIDTH(DATA_MEM_WIDTH),
      .INIT_FILE("")
  ) u_dccm (
      .clk          (core_clk),
      .rstn         (axi_rstn_c),
      .s_axi_arid   (dmem_arid),
      .s_axi_araddr (dmem_araddr),
      .s_axi_arlen  (dmem_arlen),
      .s_axi_arsize (dmem_arsize),
      .s_axi_arburst(dmem_arburst),
      .s_axi_arvalid(dmem_arvalid),
      .s_axi_arready(dmem_arready),
      .s_axi_rid    (dmem_rid),
      .s_axi_rdata  (dmem_rdata_axi),
      .s_axi_rresp  (dmem_rresp),
      .s_axi_rlast  (dmem_rlast),
      .s_axi_rvalid (dmem_rvalid),
      .s_axi_rready (dmem_rready),
      .s_axi_awid   (dmem_awid),
      .s_axi_awaddr (dmem_awaddr),
      .s_axi_awlen  (dmem_awlen),
      .s_axi_awsize (dmem_awsize),
      .s_axi_awburst(dmem_awburst),
      .s_axi_awvalid(dmem_awvalid),
      .s_axi_awready(dmem_awready),
      .s_axi_wdata  (dmem_wdata_axi),
      .s_axi_wstrb  (dmem_wstrb_axi),
      .s_axi_wlast  (dmem_wlast),
      .s_axi_wvalid (dmem_wvalid),
      .s_axi_wready (dmem_wready),
      .s_axi_bid    (dmem_bid),
      .s_axi_bresp  (dmem_bresp),
      .s_axi_bvalid (dmem_bvalid),
      .s_axi_bready (dmem_bready),
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
    else if (dccm_wen && core_rstn && dccm_is_eot) eot_done_c_r <= 1'b1;
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
      else if (dccm_wen && core_rstn && dccm_is_uart && !uart_busy_c) begin
        uart_data_c <= dccm_wdata[7:0];
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
      .dccm_wdata(dccm_wdata), .dccm_wstrb(dccm_wstrb)
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

endmodule
