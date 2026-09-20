// Generated on 2026-09-19 14:13:47 - DO NOT EDIT, REGENERATE INSTEAD

`ifndef CSR_PKG_SVH
`define CSR_PKG_SVH

package csr_pkg;
  localparam logic [11:0] CSR_VSTART_ADDR = 12'h008;
  localparam int CSR_VSTART_VSTART_HI = 31;
  localparam int CSR_VSTART_VSTART_LO = 0;
  localparam logic [11:0] CSR_VL_ADDR = 12'hC20;
  localparam int CSR_VL_VL_HI = 31;
  localparam int CSR_VL_VL_LO = 0;
  localparam logic [11:0] CSR_VTYPE_ADDR = 12'hC21;
  localparam int CSR_VTYPE_VILL_HI = 31;
  localparam int CSR_VTYPE_VILL_LO = 31;
  localparam int CSR_VTYPE_VMA_HI = 7;
  localparam int CSR_VTYPE_VMA_LO = 7;
  localparam int CSR_VTYPE_VTA_HI = 6;
  localparam int CSR_VTYPE_VTA_LO = 6;
  localparam int CSR_VTYPE_VSEW_HI = 5;
  localparam int CSR_VTYPE_VSEW_LO = 3;
  localparam int CSR_VTYPE_VLMUL_HI = 2;
  localparam int CSR_VTYPE_VLMUL_LO = 0;
  localparam logic [11:0] CSR_VLENB_ADDR = 12'hC22;
  localparam int CSR_VLENB_VLENB_HI = 31;
  localparam int CSR_VLENB_VLENB_LO = 0;
endpackage

`endif
