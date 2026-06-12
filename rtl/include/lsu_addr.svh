`ifndef LSU_ADDR_SVH
`define LSU_ADDR_SVH

// Effective byte address for a queued or streaming LSU memory operation.
function automatic logic [XLEN-1:0] lsu_effective_addr(input lsu_mem_op_t op);
  logic [XLEN-1:0] imm_se;
  imm_se = {{XLEN - 12{op.imm[11]}}, op.imm[11:0]};
  return op.rs1_data + imm_se;
endfunction

// Pack a live IDU1 operand bundle into the LSU memory-operation struct.
function automatic lsu_mem_op_t lsu_pack_req(
    input idu1_out_t ctrl,
    input logic [LSU_LANE_ID_WIDTH-1:0] lane
);
  lsu_mem_op_t op;
  op.lane_id   = lane;
  op.instr     = ctrl.instr;
  op.instr_tag = ctrl.instr_tag;
  op.rs1_data  = ctrl.rs1_data;
  op.rs2_data  = ctrl.rs2_data;
  op.rd_addr   = ctrl.rd_addr;
  op.imm       = ctrl.imm;
  op.by        = ctrl.by;
  op.half      = ctrl.half;
  op.word      = ctrl.word;
  op.load      = ctrl.load;
  op.store     = ctrl.store;
  op.unsign    = ctrl.unsign;
  op.legal     = ctrl.legal;
  return op;
endfunction

`endif
