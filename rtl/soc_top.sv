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
    output logic [XLEN-1:0]  core_dccm_waddr,
    output logic             core_dccm_wen,
    output logic [XLEN-1:0]  core_dccm_wdata
`endif

);

  localparam logic [XLEN-1:0] UART_ADDRESS = 32'h00200000;
  localparam logic [XLEN-1:0] EOT_ADDRESS  = 32'h10000000;

  logic      [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr;
  logic                                 instr_mem_addr_valid;
  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_out;
  logic      [     INSTR_MEM_WIDTH-1:0] instr_mem_rdata;
  logic                                 instr_mem_rdata_valid;
  logic      [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in;

  logic      [                XLEN-1:0] dccm_raddr;
  logic                                 dccm_rvalid_in;
  logic      [                XLEN-1:0] dccm_rdata;
  logic                                 dccm_rvalid_out;
  logic      [                XLEN-1:0] dccm_waddr;
  logic                                 dccm_wen;
  logic      [                XLEN-1:0] dccm_wdata;
  logic      [                     3:0] dccm_wstrb;

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
      .dccm_wstrb           (dccm_wstrb)
`ifndef SYNTHESIS
      ,
      .debug(core_debug)
`endif
  );

`ifndef SYNTHESIS
  assign core_dccm_waddr = dccm_waddr;
  assign core_dccm_wen   = dccm_wen;
  assign core_dccm_wdata = dccm_wdata;
`endif

  logic dccm_is_mmio;
  logic dccm_wen_mem;
  assign dccm_is_mmio = (dccm_waddr == UART_ADDRESS) || (dccm_waddr == EOT_ADDRESS);
  assign dccm_wen_mem = dccm_wen & ~dccm_is_mmio;

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

  logic [   AXI_ID_WIDTH-1:0] dmem_arid;
  logic [ AXI_ADDR_WIDTH-1:0] dmem_araddr;
  logic [   AXI_LEN_WIDTH-1:0] dmem_arlen;
  logic [  AXI_SIZE_WIDTH-1:0] dmem_arsize;
  logic [ AXI_BURST_WIDTH-1:0] dmem_arburst;
  logic                        dmem_arvalid;
  logic                        dmem_arready;
  logic [   AXI_ID_WIDTH-1:0] dmem_rid;
  logic [AXI_DATA_WIDTH-1:0]  dmem_rdata;
  logic [ AXI_RESP_WIDTH-1:0] dmem_rresp;
  logic                        dmem_rlast;
  logic                        dmem_rvalid;
  logic                        dmem_rready;

  logic [   AXI_ID_WIDTH-1:0] dmem_awid;
  logic [ AXI_ADDR_WIDTH-1:0] dmem_awaddr;
  logic [   AXI_LEN_WIDTH-1:0] dmem_awlen;
  logic [  AXI_SIZE_WIDTH-1:0] dmem_awsize;
  logic [ AXI_BURST_WIDTH-1:0] dmem_awburst;
  logic                        dmem_awvalid;
  logic                        dmem_awready;
  logic [AXI_DATA_WIDTH-1:0]  dmem_wdata;
  logic [AXI_STRB_WIDTH-1:0]  dmem_wstrb;
  logic                        dmem_wlast;
  logic                        dmem_wvalid;
  logic                        dmem_wready;
  logic [   AXI_ID_WIDTH-1:0] dmem_bid;
  logic [ AXI_RESP_WIDTH-1:0] dmem_bresp;
  logic                        dmem_bvalid;
  logic                        dmem_bready;

  dmem_to_axi4 u_dmem_ad (
      .clk            (clk),
      .rstn           (rstn),
      .dccm_raddr     (dccm_raddr),
      .dccm_rvalid_in (dccm_rvalid_in),
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
      .m_axi_rdata    (dmem_rdata),
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
      .m_axi_wdata    (dmem_wdata),
      .m_axi_wstrb    (dmem_wstrb),
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
      .INIT_FILE(DCCM_INIT_FILE)
  ) u_dccm (
      .clk          (clk),
      .rstn         (rstn),
      .s_axi_arid   (dmem_arid),
      .s_axi_araddr (dmem_araddr),
      .s_axi_arlen  (dmem_arlen),
      .s_axi_arsize (dmem_arsize),
      .s_axi_arburst(dmem_arburst),
      .s_axi_arvalid(dmem_arvalid),
      .s_axi_arready(dmem_arready),
      .s_axi_rid    (dmem_rid),
      .s_axi_rdata  (dmem_rdata),
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
      .s_axi_wdata  (dmem_wdata),
      .s_axi_wstrb  (dmem_wstrb),
      .s_axi_wlast  (dmem_wlast),
      .s_axi_wvalid (dmem_wvalid),
      .s_axi_wready (dmem_wready),
      .s_axi_bid    (dmem_bid),
      .s_axi_bresp  (dmem_bresp),
      .s_axi_bvalid (dmem_bvalid),
      .s_axi_bready (dmem_bready),
      .host_sel     (1'b0),
      .host_en      (1'b0),
      .host_wr      (1'b0),
      .host_addr    ('0),
      .host_din     ('0),
      .host_wstrb   ('0),
      .host_dout    (),
      .host_rvalid  ()
  );

endmodule
