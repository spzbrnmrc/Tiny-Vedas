// Production multiplier pipeline config (32-bit exu_mul / SVLib mul).
//
// PD (ASAP7): CPA=2 (two 32-bit lanes + carry reg) + CSA_LR2 breaks the
// Booth→CSA→CPA path; exu_mul drops the e3 product flop to hold latency.
//
// Inner mul latency = 2 (CPA=2) + 1 (CSA_LR2) = 3 cycles from e2 operands.

`ifndef MUL_PD_CONFIG_SVH
`define MUL_PD_CONFIG_SVH

`define MUL_PIPE_STAGE_AFTER_BOOTH 0
`define MUL_PIPE_STAGE_CSA_LR1 0
`define MUL_PIPE_STAGE_CSA_LR2 0
`define MUL_PIPE_STAGE_CSA_LR3 1
`define MUL_PIPE_STAGE_CSA_LR4 0
`define MUL_PIPE_STAGES_CPA 2

`endif
