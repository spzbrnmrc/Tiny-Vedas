///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.
///////////////////////////////////////////////////////////////////////////////
//   Description : Tiny Vedas - Divide / remainder unit
//
//   Fast path (one cycle after issue):
//     - divide by zero, divide by one, dividend zero, signed overflow
//     - 4-bit magnitude small_div (both |rs1| and |rs2| fit in 4 bits)
//
//   Slow path:
//     - 32-step non-restoring binary divider on absolute magnitudes
///////////////////////////////////////////////////////////////////////////////

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

module div (
    input  logic                 clk,
    input  logic                 rstn,
    input  logic                 dec_tlu_fast_div_disable,
    input  idu1_out_t            dp,
    input  logic                 flush_lower,
    output logic                 valid_ff_e1,
    output logic                 finish_early,
    output logic                 finish,
    output logic                 div_stall,
    output logic [        31:0]  out,
    output logic [         4:0]  out_addr,
    output logic                 out_valid
`ifndef SYNTHESIS
    ,
    output logic [XLEN-1:0]      instr_tag_out,
    output logic [        31:0]  instr_out
`endif
);

  typedef enum logic [1:0] {
    DIV_S_IDLE,
    DIV_S_RUN,
    DIV_S_DONE
  } div_state_e;

  div_state_e state;

  logic [31:0] dividend;
  logic [31:0] divisor;
  logic        rem_op;
  logic        signed_op;
  logic        dividend_neg;
  logic        divisor_neg;
  logic        div_overflow;
  logic        div_by_zero;
  logic        div_by_one;
  logic        dividend_zero;
  logic        smallnum;
  logic        fast_path;

  logic [31:0] abs_dividend;
  logic [31:0] abs_divisor;
  logic [31:0] quot_mag;
  logic [31:0] rem_mag;
  logic [31:0] quot_signed;
  logic [31:0] rem_signed;
  logic [31:0] result_fast;

  logic [3:0] small_q;
  logic [3:0] small_r;

  logic signed [32:0] part_rem;
  logic [31:0] part_quot;
  logic [ 4:0] iter;
  logic signed [32:0] aq_shift_a;
  logic [31:0] aq_shift_q;
  logic [32:0] divisor_ext;
  logic [32:0] trial_addend;
  logic        trial_cin;
  logic [63:0] trial_rem_ext;
  logic signed [32:0] trial_rem;
  logic [31:0] next_quot;
  logic signed [32:0] next_rem;
  logic [31:0] rem_iter_sum;
  logic [31:0] quot_iter;
  logic [31:0] rem_iter;

  logic [31:0] result_run;
  logic [31:0] result_latched;
  logic [31:0] result_done;
  logic [31:0] quot_iter_signed;
  logic [31:0] rem_iter_signed;
  logic        fast_path_ff;
  logic        rem_op_ff;
  logic        signed_op_ff;
  logic        dividend_neg_ff;
  logic        divisor_neg_ff;
  logic        flush_lower_ff;
  logic [31:0] abs_divisor_ff;

  assign dividend = dp.rs1_data;
  assign divisor  = dp.rs2_data;
  assign rem_op   = dp.rem;
  assign signed_op = ~dp.unsign;

  assign dividend_neg = signed_op & dividend[31];
  assign divisor_neg  = signed_op & divisor[31];

  assign abs_dividend = dividend_neg ? (~dividend + 1'b1) : dividend;
  assign abs_divisor  = divisor_neg ? (~divisor + 1'b1) : divisor;

  assign div_by_zero   = (divisor == 32'b0);
  assign div_by_one    = (abs_divisor == 32'd1);
  assign dividend_zero = (dividend == 32'b0);
  assign div_overflow  = signed_op & (dividend == 32'h8000_0000) & (divisor == 32'hFFFF_FFFF);

  assign smallnum = ~dec_tlu_fast_div_disable
      & ~div_by_zero
      & ~div_by_one
      & ~div_overflow
      & (abs_dividend[31:4] == 28'b0)
      & (abs_divisor[31:4] == 28'b0);

  assign fast_path = div_by_zero | div_by_one | dividend_zero | div_overflow | smallnum;

  small_div small_div_inst (
      .a(abs_dividend[3:0]),
      .b(abs_divisor[3:0]),
      .q(small_q),
      .r(small_r)
  );

  always_comb begin
    quot_mag = 32'b0;
    rem_mag  = 32'b0;

    if (div_by_zero) begin
      quot_mag = 32'hFFFF_FFFF;
      rem_mag  = dividend;
    end else if (dividend_zero) begin
      quot_mag = 32'b0;
      rem_mag  = 32'b0;
    end else if (div_by_one) begin
      quot_mag = abs_dividend;
      rem_mag  = 32'b0;
    end else if (div_overflow) begin
      quot_mag = 32'h8000_0000;
      rem_mag  = 32'b0;
    end else if (smallnum) begin
      quot_mag = {28'b0, small_q};
      rem_mag  = {28'b0, small_r};
    end
  end

  function automatic logic [31:0] apply_neg32(input logic [31:0] mag, input logic neg);
    apply_neg32 = neg ? (~mag + 1'b1) : mag;
  endfunction

  assign quot_signed = apply_neg32(quot_mag, signed_op & (dividend_neg ^ divisor_neg));
  assign rem_signed  = apply_neg32(rem_mag, signed_op & dividend_neg);

  assign result_fast = rem_op ? rem_signed : quot_signed;

  assign aq_shift_a  = {part_rem[31:0], part_quot[31]};
  assign aq_shift_q  = part_quot << 1;
  assign divisor_ext = {1'b0, abs_divisor_ff};

  assign trial_addend = part_rem[32] ? divisor_ext : ~divisor_ext;
  assign trial_cin    = ~part_rem[32];

  kogge_stone_adder #(
      .WIDTH(64)
  ) trial_rem_adder (
      .in0  ({31'b0, aq_shift_a}),
      .in1  ({31'b0, trial_addend}),
      .cin  (trial_cin),
      .sum  (trial_rem_ext),
      .cout ()
  );

  assign trial_rem = trial_rem_ext[32:0];

  assign next_quot = {aq_shift_q[31:1], ~trial_rem[32]};
  assign next_rem  = trial_rem;

  kogge_stone_adder #(
      .WIDTH(32)
  ) rem_iter_adder (
      .in0  (part_rem[31:0]),
      .in1  (abs_divisor_ff),
      .cin  (1'b0),
      .sum  (rem_iter_sum),
      .cout ()
  );

  assign quot_iter = part_quot;
  assign rem_iter  = part_rem[32] ? rem_iter_sum : part_rem[31:0];

  assign quot_iter_signed = apply_neg32(quot_iter, signed_op_ff & (dividend_neg_ff ^ divisor_neg_ff));
  assign rem_iter_signed  = apply_neg32(rem_iter, signed_op_ff & dividend_neg_ff);

  assign result_run = rem_op_ff ? rem_iter_signed : quot_iter_signed;

  assign result_done = fast_path_ff ? result_latched : result_run;

  assign finish       = (state == DIV_S_DONE);
  assign finish_early = finish & fast_path_ff;
  assign div_stall    = (state != DIV_S_IDLE);
  assign out          = result_done;

  assign valid_ff_e1 = (state != DIV_S_IDLE) | (dp.legal & dp.div & ~flush_lower_ff);

  register_sync_rstn #(
      .WIDTH(1)
  ) flush_any_ff (
      .clk (clk),
      .rstn(rstn),
      .din (flush_lower),
      .dout(flush_lower_ff)
  );

  register_en_sync_rstn #(
      .WIDTH(5)
  ) out_addr_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (dp.legal & dp.div),
      .din (dp.rd_addr),
      .dout(out_addr)
  );

`ifndef SYNTHESIS
  register_en_sync_rstn #(
      .WIDTH(XLEN + INSTR_LEN)
  ) instr_tag_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (dp.legal & dp.div),
      .din ({dp.instr_tag, dp.instr}),
      .dout({instr_tag_out, instr_out})
  );
`endif

  register #(
      .WIDTH(1)
  ) out_valid_ff (
      .clk (clk),
      .din (finish),
      .dout(out_valid)
  );

  logic flush_fire;
  logic issue_fire;
  logic run_fire;
  logic done_fire;

  logic [1:0] state_din;
  logic       state_en;

  logic [4:0] iter_din;
  logic       iter_en;

  logic signed [32:0] part_rem_din;
  logic               part_rem_en;

  logic [31:0] part_quot_din;
  logic        part_quot_en;

  logic [31:0] abs_divisor_din;
  logic        abs_divisor_en;

  logic [31:0] result_latched_din;
  logic        result_latched_en;

  logic fast_path_din;
  logic fast_path_en;

  logic rem_op_din;
  logic rem_op_en;

  logic signed_op_din;
  logic signed_op_en;

  logic dividend_neg_din;
  logic dividend_neg_en;

  logic divisor_neg_din;
  logic divisor_neg_en;

  assign flush_fire = flush_lower | flush_lower_ff;
  assign issue_fire = dp.legal & dp.div & (state == DIV_S_IDLE) & ~flush_fire;
  assign run_fire   = (state == DIV_S_RUN) & ~flush_fire;
  assign done_fire  = (state == DIV_S_DONE) & ~flush_fire;

  always_comb begin
    state_din = state;
    unique case (state)
      DIV_S_IDLE:  state_en = flush_fire | issue_fire;
      DIV_S_RUN:   state_en = flush_fire | run_fire;
      DIV_S_DONE:  state_en = flush_fire | done_fire;
      default:     state_en = 1'b1;
    endcase

    iter_din = iter;
    iter_en  = issue_fire | run_fire;

    part_rem_din = part_rem;
    part_rem_en  = issue_fire | run_fire;

    part_quot_din = part_quot;
    part_quot_en  = issue_fire | run_fire;

    abs_divisor_din = abs_divisor_ff;
    abs_divisor_en  = issue_fire;

    result_latched_din = result_latched;
    result_latched_en  = issue_fire;

    fast_path_din = fast_path_ff;
    fast_path_en  = issue_fire;

    rem_op_din = rem_op_ff;
    rem_op_en  = issue_fire;

    signed_op_din = signed_op_ff;
    signed_op_en  = issue_fire;

    dividend_neg_din = dividend_neg_ff;
    dividend_neg_en  = issue_fire;

    divisor_neg_din = divisor_neg_ff;
    divisor_neg_en  = issue_fire;

    if (flush_fire) begin
      state_din = DIV_S_IDLE;
    end else if (issue_fire) begin
      fast_path_din    = fast_path;
      rem_op_din       = rem_op;
      signed_op_din    = signed_op;
      dividend_neg_din = dividend_neg;
      divisor_neg_din  = divisor_neg;
      abs_divisor_din  = abs_divisor;
      result_latched_din = result_fast;

      if (fast_path) begin
        state_din = DIV_S_DONE;
      end else begin
        state_din   = DIV_S_RUN;
        iter_din    = 5'd0;
        part_rem_din  = 33'sd0;
        part_quot_din = abs_dividend;
      end
    end else if (run_fire) begin
      part_rem_din  = next_rem;
      part_quot_din = next_quot;
      if (iter == 5'd31) begin
        state_din = DIV_S_DONE;
      end else begin
        iter_din = iter + 5'd1;
      end
    end else if (done_fire) begin
      state_din = DIV_S_IDLE;
    end else if (state_en) begin
      state_din = DIV_S_IDLE;
    end
  end

  register_en_sync_rstn #(
      .WIDTH(2),
      .RESET_VAL(2'(DIV_S_IDLE))
  ) state_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (state_en),
      .din (state_din),
      .dout(state)
  );

  register_en_sync_rstn #(
      .WIDTH(5)
  ) iter_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (iter_en),
      .din (iter_din),
      .dout(iter)
  );

  register_en_sync_rstn #(
      .WIDTH(33)
  ) part_rem_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (part_rem_en),
      .din (part_rem_din),
      .dout(part_rem)
  );

  register_en_sync_rstn #(
      .WIDTH(32)
  ) part_quot_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (part_quot_en),
      .din (part_quot_din),
      .dout(part_quot)
  );

  register_en_sync_rstn #(
      .WIDTH(32)
  ) abs_divisor_ff_inst (
      .clk (clk),
      .rstn(rstn),
      .en  (abs_divisor_en),
      .din (abs_divisor_din),
      .dout(abs_divisor_ff)
  );

  register_en_sync_rstn #(
      .WIDTH(32)
  ) result_latched_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (result_latched_en),
      .din (result_latched_din),
      .dout(result_latched)
  );

  register_en_sync_rstn #(
      .WIDTH(1)
  ) fast_path_ff_inst (
      .clk (clk),
      .rstn(rstn),
      .en  (fast_path_en),
      .din (fast_path_din),
      .dout(fast_path_ff)
  );

  register_en_sync_rstn #(
      .WIDTH(1)
  ) rem_op_ff_inst (
      .clk (clk),
      .rstn(rstn),
      .en  (rem_op_en),
      .din (rem_op_din),
      .dout(rem_op_ff)
  );

  register_en_sync_rstn #(
      .WIDTH(1)
  ) signed_op_ff_inst (
      .clk (clk),
      .rstn(rstn),
      .en  (signed_op_en),
      .din (signed_op_din),
      .dout(signed_op_ff)
  );

  register_en_sync_rstn #(
      .WIDTH(1)
  ) dividend_neg_ff_inst (
      .clk (clk),
      .rstn(rstn),
      .en  (dividend_neg_en),
      .din (dividend_neg_din),
      .dout(dividend_neg_ff)
  );

  register_en_sync_rstn #(
      .WIDTH(1)
  ) divisor_neg_ff_inst (
      .clk (clk),
      .rstn(rstn),
      .en  (divisor_neg_en),
      .din (divisor_neg_din),
      .dout(divisor_neg_ff)
  );

endmodule
