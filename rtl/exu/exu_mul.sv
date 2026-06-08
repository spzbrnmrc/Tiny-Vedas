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
//   Description : Tiny Vedas - EXU multiply unit (uses SVLib booth mul)
///////////////////////////////////////////////////////////////////////////////

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

`ifndef MUL_PD_CONFIG_SVH
`include "mul_pd_config.svh"
`endif

module exu_mul (
    input  logic                 clk,
    input  logic                 rstn,
    input  logic                 freeze,
    input  idu1_out_t            mul_ctrl,
    output logic      [XLEN-1:0] out,
    output logic      [     4:0] out_rd_addr,
    output logic                 out_rd_wr_en,
    output logic      [XLEN-1:0] instr_tag_out,
    output logic      [    31:0] instr_out,
    output logic                 mul_busy
);

  localparam int MUL_LAT = 1 + `MUL_PIPE_STAGE_AFTER_BOOTH + `MUL_PIPE_STAGE_CSA_LR1 + `MUL_PIPE_STAGE_CSA_LR2 + `MUL_PIPE_STAGE_CSA_LR3 + `MUL_PIPE_STAGE_CSA_LR4 + `MUL_PIPE_STAGES_CPA + 1;

  logic [XLEN-1:0] a_ff_e1, a_e1;
  logic [XLEN-1:0] b_ff_e1, b_e1;
  logic rs1_sign_e1, rs1_sign_e2, rs1_neg_e1;
  logic rs2_sign_e1, rs2_sign_e2, rs2_neg_e1;
  logic signed [XLEN:0] a_ff_e2, b_ff_e2;
  logic signed [ 2*XLEN:0] prod_e3;

  logic        [MUL_LAT:0] low_e;
  logic        [      4:0] out_rd_addr_e  [MUL_LAT:0];
  logic        [MUL_LAT:0] out_rd_wr_en_e;

  logic        [ XLEN-1:0] instr_tag_e    [MUL_LAT:0];
  logic        [     31:0] instr_e        [MUL_LAT:0];

  logic [XLEN-1:0] a, b;

  assign a = mul_ctrl.rs1_data;
  assign b = mul_ctrl.rs2_data;

  // --------------------------- Input flops - Datapath ----------------------------------

  register_sync_rstn #(
      .WIDTH(1)
  ) rs1_sign_e1_ff (
      .clk (clk),
      .rstn(rstn),
      .din (mul_ctrl.rs1_sign),
      .dout(rs1_sign_e1)
  );
  register_sync_rstn #(
      .WIDTH(1)
  ) rs2_sign_e1_ff (
      .clk (clk),
      .rstn(rstn),
      .din (mul_ctrl.rs2_sign),
      .dout(rs2_sign_e1)
  );

  register_sync_rstn #(
      .WIDTH(XLEN)
  ) a_e1_ff (
      .clk (clk),
      .rstn(rstn),
      .din (a[XLEN-1:0]),
      .dout(a_ff_e1[XLEN-1:0])
  );
  register_sync_rstn #(
      .WIDTH(XLEN)
  ) b_e1_ff (
      .clk (clk),
      .rstn(rstn),
      .din (b[XLEN-1:0]),
      .dout(b_ff_e1[XLEN-1:0])
  );

  // --------------------------- Input flops - Sideband ----------------------------------
  genvar lat;
  generate
    assign low_e[0]          = mul_ctrl.low;
    assign out_rd_addr_e[0]  = mul_ctrl.rd_addr;
    assign out_rd_wr_en_e[0] = mul_ctrl.legal & mul_ctrl.mul;
    assign instr_tag_e[0]    = mul_ctrl.instr_tag;
    assign instr_e[0]        = mul_ctrl.instr;
    for (lat = 0; lat < MUL_LAT; lat++) begin : gen_sideband_ff

      register_sync_rstn #(
          .WIDTH(1)
      ) sideband_ff (
          .clk (clk),
          .rstn(rstn),
          .din (low_e[lat]),
          .dout(low_e[lat+1])
      );

      register_sync_rstn #(
          .WIDTH(5)
      ) out_rd_addr_ff (
          .clk (clk),
          .rstn(rstn),
          .din (out_rd_addr_e[lat]),
          .dout(out_rd_addr_e[lat+1])
      );

      register_sync_rstn #(
          .WIDTH(1)
      ) out_rd_wr_en_ff (
          .clk (clk),
          .rstn(rstn),
          .din (out_rd_wr_en_e[lat]),
          .dout(out_rd_wr_en_e[lat+1])
      );

      register_sync_rstn #(
          .WIDTH(XLEN * 2)
      ) instr_tag_ff (
          .clk (clk),
          .rstn(rstn),
          .din ({instr_tag_e[lat], instr_e[lat]}),
          .dout({instr_tag_e[lat+1], instr_e[lat+1]})
      );
    end
  endgenerate

  // --------------------------- E1 Logic Stage ----------------------------------

  assign a_e1[XLEN-1:0] = a_ff_e1[XLEN-1:0];
  assign b_e1[XLEN-1:0] = b_ff_e1[XLEN-1:0];

  assign rs1_neg_e1 = rs1_sign_e1 & a_e1[XLEN-1];
  assign rs2_neg_e1 = rs2_sign_e1 & b_e1[XLEN-1];


  register_sync_rstn #(
      .WIDTH(1)
  ) rs1_sign_e2_ff (
      .clk (clk),
      .rstn(rstn),
      .din (rs1_sign_e1),
      .dout(rs1_sign_e2)
  );
  register_sync_rstn #(
      .WIDTH(1)
  ) rs2_sign_e2_ff (
      .clk (clk),
      .rstn(rstn),
      .din (rs2_sign_e1),
      .dout(rs2_sign_e2)
  );

  register_sync_rstn #(
      .WIDTH(XLEN + 1)
  ) a_e2_ff (
      .clk (clk),
      .rstn(rstn),
      .din ({rs1_neg_e1, a_e1[XLEN-1:0]}),
      .dout(a_ff_e2[XLEN:0])
  );
  register_sync_rstn #(
      .WIDTH(XLEN + 1)
  ) b_e2_ff (
      .clk (clk),
      .rstn(rstn),
      .din ({rs2_neg_e1, b_e1[XLEN-1:0]}),
      .dout(b_ff_e2[XLEN:0])
  );

  // ---------------------- E2 Logic Stage --------------------------

  logic signed [2 * XLEN+1:0] prod_e2;
  logic [XLEN-1:0] booth_lower;
  logic [XLEN-1:0] booth_upper;

  mul #(
      .WIDTH                 (XLEN),
      .CPA_ALGORITHM         (2),
      .PIPE_STAGE_AFTER_BOOTH(`MUL_PIPE_STAGE_AFTER_BOOTH),
      .PIPE_STAGE_CSA_LR1    (`MUL_PIPE_STAGE_CSA_LR1),
      .PIPE_STAGE_CSA_LR2    (`MUL_PIPE_STAGE_CSA_LR2),
      .PIPE_STAGE_CSA_LR3    (`MUL_PIPE_STAGE_CSA_LR3),
      .PIPE_STAGE_CSA_LR4    (`MUL_PIPE_STAGE_CSA_LR4),
      .PIPE_STAGES_CPA       (`MUL_PIPE_STAGES_CPA)
  ) booth_mul_inst (
      .clk   (clk),
      .a     (a_ff_e2[XLEN-1:0]),
      .a_sign(rs1_sign_e2),
      .b     (b_ff_e2[XLEN-1:0]),
      .b_sign(rs2_sign_e2),
      .lower (booth_lower),
      .upper (booth_upper)
  );

  register_sync_rstn #(
      .WIDTH(2 * XLEN + 1)
  ) prod_e3_ff (
      .clk (clk),
      .rstn(rstn),
      .din ({1'b0, booth_upper, booth_lower}),
      .dout(prod_e3[2*XLEN:0])
  );

  // ----------------------- E3 Logic Stage -------------------------

  assign out[XLEN-1:0] = low_e[MUL_LAT] ? prod_e3[XLEN-1:0] : prod_e3[2*XLEN-1:XLEN];
  assign out_rd_wr_en  = out_rd_wr_en_e[MUL_LAT];
  assign out_rd_addr   = out_rd_addr_e[MUL_LAT];

  assign mul_busy      = |out_rd_wr_en_e[MUL_LAT-1:1];

  assign instr_tag_out = instr_tag_e[MUL_LAT];
  assign instr_out     = instr_e[MUL_LAT];

endmodule
