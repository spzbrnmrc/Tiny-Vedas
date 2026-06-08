// Production multiplier pipeline config (32-bit exu_mul / SVLib mul).
//
// PD (ASAP7): CSA_LR3 flop + kogge_stone_pipe CPA (CPA_ALGORITHM=2 in exu_mul).
// Align MUL_LAT in exu_mul with the single enabled internal pipe stage.
//
// Inner mul latency from e2 operands: 1 (CSA_LR3) + 2 (kogge_stone_pipe CPA) cycles
// through SVLib, plus exu_mul boundary flops — see exu_mul MUL_LAT.

`ifndef MUL_PD_CONFIG_SVH
`define MUL_PD_CONFIG_SVH

`define MUL_PIPE_STAGE_AFTER_BOOTH 0
`define MUL_PIPE_STAGE_CSA_LR1 0
`define MUL_PIPE_STAGE_CSA_LR2 0
`define MUL_PIPE_STAGE_CSA_LR3 1
`define MUL_PIPE_STAGE_CSA_LR4 0
`define MUL_PIPE_STAGES_CPA 2

`endif
