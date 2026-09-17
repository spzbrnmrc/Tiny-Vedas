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
    output logic [XLEN-1:0] mmio_dev_wdata [MMIO_DEV_COUNT-1:0]
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

  generate
    for (gp = 0; gp < LSU_DCCM_PORT_COUNT; gp++) begin : g_dmem_ad
      dmem_to_axi4 u_dmem_ad (
          .clk            (clk),
          .rstn           (rstn),
          .dccm_raddr     (dccm_raddr[gp]),
          .dccm_rvalid_in (dccm_rvalid_in[gp]),
          .dccm_rdata     (dccm_rdata[gp]),
          .dccm_rvalid_out(dccm_rvalid_out[gp]),
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

  axi4_dccm #(
      .DEPTH(DATA_MEM_DEPTH),
      .WIDTH(DATA_MEM_WIDTH),
      .INIT_FILE(DCCM_INIT_FILE)
  ) u_dccm (
      .clk          (clk),
      .rstn         (rstn),
      .s_axi_arid   (dmem_arid[0]),
      .s_axi_araddr (dmem_araddr[0]),
      .s_axi_arlen  (dmem_arlen[0]),
      .s_axi_arsize (dmem_arsize[0]),
      .s_axi_arburst(dmem_arburst[0]),
      .s_axi_arvalid(dmem_arvalid[0]),
      .s_axi_arready(dmem_arready[0]),
      .s_axi_rid    (dmem_rid[0]),
      .s_axi_rdata  (dmem_rdata_axi[0]),
      .s_axi_rresp  (dmem_rresp[0]),
      .s_axi_rlast  (dmem_rlast[0]),
      .s_axi_rvalid (dmem_rvalid[0]),
      .s_axi_rready (dmem_rready[0]),
      .s_axi_awid   (dmem_awid[0]),
      .s_axi_awaddr (dmem_awaddr[0]),
      .s_axi_awlen  (dmem_awlen[0]),
      .s_axi_awsize (dmem_awsize[0]),
      .s_axi_awburst(dmem_awburst[0]),
      .s_axi_awvalid(dmem_awvalid[0]),
      .s_axi_awready(dmem_awready[0]),
      .s_axi_wdata  (dmem_wdata_axi[0]),
      .s_axi_wstrb  (dmem_wstrb_axi[0]),
      .s_axi_wlast  (dmem_wlast[0]),
      .s_axi_wvalid (dmem_wvalid[0]),
      .s_axi_wready (dmem_wready[0]),
      .s_axi_bid    (dmem_bid[0]),
      .s_axi_bresp  (dmem_bresp[0]),
      .s_axi_bvalid (dmem_bvalid[0]),
      .s_axi_bready (dmem_bready[0]),
      .s1_axi_arid   (dmem_arid[1]),
      .s1_axi_araddr (dmem_araddr[1]),
      .s1_axi_arlen  (dmem_arlen[1]),
      .s1_axi_arsize (dmem_arsize[1]),
      .s1_axi_arburst(dmem_arburst[1]),
      .s1_axi_arvalid(dmem_arvalid[1]),
      .s1_axi_arready(dmem_arready[1]),
      .s1_axi_rid    (dmem_rid[1]),
      .s1_axi_rdata  (dmem_rdata_axi[1]),
      .s1_axi_rresp  (dmem_rresp[1]),
      .s1_axi_rlast  (dmem_rlast[1]),
      .s1_axi_rvalid (dmem_rvalid[1]),
      .s1_axi_rready (dmem_rready[1]),
      .s1_axi_awid   (dmem_awid[1]),
      .s1_axi_awaddr (dmem_awaddr[1]),
      .s1_axi_awlen  (dmem_awlen[1]),
      .s1_axi_awsize (dmem_awsize[1]),
      .s1_axi_awburst(dmem_awburst[1]),
      .s1_axi_awvalid(dmem_awvalid[1]),
      .s1_axi_awready(dmem_awready[1]),
      .s1_axi_wdata  (dmem_wdata_axi[1]),
      .s1_axi_wstrb  (dmem_wstrb_axi[1]),
      .s1_axi_wlast  (dmem_wlast[1]),
      .s1_axi_wvalid (dmem_wvalid[1]),
      .s1_axi_wready (dmem_wready[1]),
      .s1_axi_bid    (dmem_bid[1]),
      .s1_axi_bresp  (dmem_bresp[1]),
      .s1_axi_bvalid (dmem_bvalid[1]),
      .s1_axi_bready (dmem_bready[1]),
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
