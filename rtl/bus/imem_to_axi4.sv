///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Custom tagged IFU fetch port -> AXI4 read master (1 outstanding).
// PC tag is scored in a 1-deep table keyed by ARID (fixed 0); not placed on ARID.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module imem_to_axi4 (
    input logic clk,
    input logic rstn,

    input  logic [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr,
    input  logic                            instr_mem_addr_valid,
    input  logic [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_out,
    output logic [     INSTR_MEM_WIDTH-1:0] instr_mem_rdata,
    output logic                            instr_mem_rdata_valid,
    output logic [ INSTR_MEM_TAG_WIDTH-1:0] instr_mem_tag_in,

    output logic [   AXI_ID_WIDTH-1:0] m_axi_arid,
    output logic [ AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [   AXI_LEN_WIDTH-1:0] m_axi_arlen,
    output logic [  AXI_SIZE_WIDTH-1:0] m_axi_arsize,
    output logic [ AXI_BURST_WIDTH-1:0] m_axi_arburst,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,
    input  logic [   AXI_ID_WIDTH-1:0] m_axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  logic [ AXI_RESP_WIDTH-1:0] m_axi_rresp,
    input  logic                        m_axi_rlast,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rready
);

  localparam logic [AXI_ID_WIDTH-1:0] FETCH_ID = '0;

  logic busy;
  logic hold;
  logic [INSTR_MEM_ADDR_WIDTH-1:0] last_addr;
  logic [INSTR_MEM_TAG_WIDTH-1:0] tag_q;
  logic [INSTR_MEM_WIDTH-1:0] rdata_q;

  logic addr_changed;
  logic sequential;
  logic redirect;
  logic new_req;
  logic ar_fire;
  logic r_fire;

  assign addr_changed = (instr_mem_addr != last_addr);
  assign sequential   = (instr_mem_addr == (last_addr + INSTR_LEN_BYTES));
  /* Non-sequential PC (branch/jal/exception). Do not present the in-flight
   * sequential beat — that skipped the beq target (lui) in asm.basic_beq. */
  assign redirect     = instr_mem_addr_valid & addr_changed & ~sequential;
  assign ar_fire      = m_axi_arvalid & m_axi_arready;
  assign r_fire       = m_axi_rvalid & m_axi_rready & busy;

  /* IFU PC free-runs (1-cycle BRAM). Request the current PC whenever it is not
   * already in flight or held. Chain AR with R so PC+4 is fetched the cycle
   * data for PC returns. */
  assign new_req = instr_mem_addr_valid & (addr_changed | (~hold & ~busy));

  assign m_axi_arid    = FETCH_ID;
  assign m_axi_araddr  = {{(AXI_ADDR_WIDTH - INSTR_MEM_ADDR_WIDTH) {1'b0}}, instr_mem_addr};
  assign m_axi_arlen   = '0;
  assign m_axi_arsize  = AXI_SIZE_4B;
  assign m_axi_arburst = AXI_BURST_INCR;
  assign m_axi_arvalid = new_req & (~busy | r_fire);
  assign m_axi_rready  = 1'b1;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      busy      <= 1'b0;
      hold      <= 1'b0;
      last_addr <= '0;
      tag_q     <= '0;
      rdata_q   <= '0;
    end else begin
      if (r_fire) begin
        rdata_q <= m_axi_rdata;
      end
      if (ar_fire) begin
        busy      <= 1'b1;
        hold      <= 1'b0;
        last_addr <= instr_mem_addr;
        tag_q     <= instr_mem_tag_out;
      end else if (r_fire) begin
        busy <= 1'b0;
        /* Drop a beat that returns during pc_load (addr_valid=0). */
        hold <= instr_mem_addr_valid;
      end else if (!instr_mem_addr_valid || redirect) begin
        hold <= 1'b0;
      end
    end
  end

  /* Present R the cycle it arrives (PC is already at the next sequential
   * fetch). Replay while held on the same PC or stall-release (PC+4). Drop
   * on redirect so a taken branch does not capture a sequential prefetch. */
  assign instr_mem_rdata       = (m_axi_rvalid & busy) ? m_axi_rdata : rdata_q;
  assign instr_mem_rdata_valid = ((m_axi_rvalid & busy) | hold) & instr_mem_addr_valid &
                                 ~redirect;
  assign instr_mem_tag_in      = tag_q;

  logic unused_axi = &{1'b0, m_axi_rid, m_axi_rresp, m_axi_rlast};

endmodule
