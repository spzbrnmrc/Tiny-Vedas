// Generated on 2026-09-19 14:13:47 - DO NOT EDIT, REGENERATE INSTEAD

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef HW_CONFIG_SVH
`include "hw_config.svh"
`endif

`ifndef CSR_PKG_SVH
`include "csr_pkg.svh"
`endif

module csr_file (
    input  logic        clk,
    input  logic        rstn,

    input  logic        csr_req,
    input  logic        csr_write,
    input  logic [11:0] csr_addr,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,
    output logic        csr_illegal,

    input  logic        vset_we,
    input  logic [31:0] vset_vl,
    input  logic [31:0] vset_vtype,

    output logic [31:0] vl,
    output logic [31:0] vtype,
    output logic [31:0] vlenb,
    output logic [31:0] vstart
);

  import csr_pkg::*;

  localparam logic [31:0] VLENB_CONST = (VLEN == 0) ? 32'd0 : 32'(VLEN / 8);

  logic [31:0] vstart_q;
  logic [31:0] vl_q;
  logic [31:0] vtype_q;
  logic [31:0] vlenb_q;

  assign vl     = vl_q;
  assign vtype  = vtype_q;
  assign vlenb  = vlenb_q;
  assign vstart = vstart_q;

  // v1: reads of known CSRs only. A write (rs1 != x0) is illegal.
  assign csr_illegal = csr_req && (csr_write || !((csr_addr == CSR_VSTART_ADDR) || (csr_addr == CSR_VL_ADDR) || (csr_addr == CSR_VTYPE_ADDR) || (csr_addr == CSR_VLENB_ADDR)));

  always_comb begin
    csr_rdata = 32'd0;
    unique case (csr_addr)
      CSR_VSTART_ADDR: csr_rdata = vstart_q;
      CSR_VL_ADDR: csr_rdata = vl_q;
      CSR_VTYPE_ADDR: csr_rdata = vtype_q;
      CSR_VLENB_ADDR: csr_rdata = vlenb_q;
      default: csr_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        vstart_q <= 32'h00000000;
        vl_q <= 32'h00000000;
        vtype_q <= 32'h80000000;
        vlenb_q <= VLENB_CONST;
    end else begin
      if (vset_we) begin
        vl_q    <= vset_vl;
        vtype_q <= vset_vtype;
        vstart_q <= 32'd0;
      end
    end
  end

endmodule
