`ifndef GEMM_CSRS_SVH
`define GEMM_CSRS_SVH

localparam logic [31:0] GEMM_OFF_BASE_A = 32'h00;
localparam logic [31:0] GEMM_OFF_BASE_B = 32'h04;
localparam logic [31:0] GEMM_OFF_BASE_C = 32'h08;
localparam logic [31:0] GEMM_OFF_M      = 32'h0C;
localparam logic [31:0] GEMM_OFF_N      = 32'h10;
localparam logic [31:0] GEMM_OFF_K      = 32'h14;
localparam logic [31:0] GEMM_OFF_CTRL   = 32'h18;
localparam logic [31:0] GEMM_OFF_STATUS = 32'h1C;

localparam int GEMM_CTRL_START_BIT = 0;
localparam int GEMM_CTRL_RESET_BIT = 1;
localparam int GEMM_STATUS_BUSY_BIT = 0;
localparam int GEMM_STATUS_DONE_BIT = 1;

localparam int GEMM_PE_DIM = 8;
localparam int GEMM_K_TILE = 32;

// 8-bit SVLib `mul` in each PE (same CPA/pipe knobs as exu_mul).
// CSA_LR2/3/4 are not generated at WIDTH=8; CPA_ALGORITHM=2 → kogge_stone_pipe.
`ifndef MUL_PD_CONFIG_SVH
`include "mul_pd_config.svh"
`endif
localparam int GEMM_MUL_PIPE_LAT = `MUL_PIPE_STAGE_AFTER_BOOTH + `MUL_PIPE_STAGE_CSA_LR1 + 1;
localparam int GEMM_PE_DRAIN = GEMM_MUL_PIPE_LAT + 1;

`endif
