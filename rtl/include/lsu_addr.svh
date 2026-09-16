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

// Byte strobes for a store/load spanning one or two words (bit i = byte i).
function automatic logic [7:0] lsu_strb_wide(
    input logic by,
    input logic half,
    input logic word,
    input logic [1:0] addr_lo
);
  logic [7:0] base;
  base = ({8{by}} & 8'h01) | ({8{half}} & 8'h03) | ({8{word}} & 8'h0F);
  return base << addr_lo;
endfunction

function automatic logic [2*XLEN-1:0] lsu_store_data_wide(
    input logic [XLEN-1:0] rs2,
    input logic [1:0] addr_lo
);
  return {{XLEN{1'b0}}, rs2} << {addr_lo, 3'b000};
endfunction

function automatic logic [XLEN-1:0] lsu_strb_to_mask(input logic [3:0] strb);
  return {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
endfunction

function automatic logic [XLEN-1:0] lsu_merge_bytes(
    input logic [XLEN-1:0] mem,
    input logic [XLEN-1:0] fwd,
    input logic [3:0] strb
);
  logic [XLEN-1:0] mask;
  mask = lsu_strb_to_mask(strb);
  return (mem & ~mask) | (fwd & mask);
endfunction

function automatic logic lsu_strb_covers(
    input logic [3:0] needed,
    input logic [3:0] have
);
  return (needed & ~have) == 4'h0;
endfunction

function automatic logic lsu_is_unaligned(
    input logic by,
    input logic half,
    input logic word,
    input logic [1:0] addr_lo
);
  return (word & (|addr_lo)) | (half & (&addr_lo));
endfunction

`endif
