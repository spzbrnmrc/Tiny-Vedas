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
// Tiny Vedas - LSU Engine (DC1/DC2/DC3)
// Dual DCCM RW ports: unaligned beat 0 + beat 1 in one cycle.
// Port 0 = reads + unaligned-store beat 1; port 1 = writes + unaligned-load beat 1.

`timescale 1ns / 1ps

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

`ifndef LSU_ADDR_SVH
`include "lsu_addr.svh"
`endif

module lsu_engine (
    input logic clk,
    input logic rstn,

    /* Dispatch Interface */
    input  lsu_mem_op_t engine_op,
    input  logic        ext_forward_valid,
    input  logic [XLEN-1:0] ext_forward_value,
    input  logic [     3:0] ext_forward_strb,
    input  logic        ext_forward_b_valid,
    input  logic [XLEN-1:0] ext_forward_b_value,
    input  logic [     3:0] ext_forward_b_strb,
    output logic        cam_lookup_valid,
    output logic [XLEN-1:0] cam_lookup_addr,
    output logic        cam_lookup_b_valid,
    output logic [XLEN-1:0] cam_lookup_b_addr,
    output logic        engine_stall,
    output logic        engine_busy,

    /* Load Writeback */
    output logic [LSU_LANE_ID_WIDTH-1:0] wb_lane_id,
    output logic [               XLEN-1:0] wb_data,
    output logic [                    4:0] wb_rd_addr,
    output logic                           wb_rd_wr_en,

    /* In-flight lane tracking (DC1/DC2) */
    output logic [LSU_LANE_ID_WIDTH-1:0] dc1_lane_id,
    output logic                         dc1_lane_valid,
    output logic [LSU_LANE_ID_WIDTH-1:0] dc2_lane_id,
    output logic                         dc2_lane_valid,

    /* Store retire (for store-queue CAM maintenance) */
    output logic            store_retire_valid,
    output logic [XLEN-1:0] store_retire_addr,
    output logic            store_retire_line_clear_valid,
    output logic [XLEN-1:0] store_retire_line_clear_addr,
    output logic            store_retire_line_clear_b_valid,
    output logic [XLEN-1:0] store_retire_line_clear_b_addr,
    output logic            store_cam_fill_valid,
    output logic [XLEN-1:0] store_cam_fill_addr,
    output logic [XLEN-1:0] store_cam_fill_data,
    output logic [     3:0] store_cam_fill_strb,
    output logic            store_cam_fill_b_valid,
    output logic [XLEN-1:0] store_cam_fill_b_addr,
    output logic [XLEN-1:0] store_cam_fill_b_data,
    output logic [     3:0] store_cam_fill_b_strb,

    /* Dual RW DCCM ports */
    output logic [XLEN-1:0] dccm_raddr     [1:0],
    output logic            dccm_rvalid_in [1:0],
    input  logic [XLEN-1:0] dccm_rdata     [1:0],
    input  logic            dccm_rvalid_out[1:0],
    output logic [XLEN-1:0] dccm_waddr     [1:0],
    output logic            dccm_wen       [1:0],
    output logic [XLEN-1:0] dccm_wdata     [1:0],
    output logic [     3:0] dccm_wstrb     [1:0]
`ifdef TV_HAS_CORE_DEBUG
    ,
    output logic [XLEN-1:0] instr_tag_out,
    output logic [    31:0] instr_out,
    output logic            debug_store_dc2_valid,
    output logic [XLEN-1:0] debug_store_dc2_instr_tag,
    output logic [    31:0] debug_store_dc2_instr,
    output logic [XLEN-1:0] debug_store_dc2_addr,
    output logic [XLEN-1:0] debug_store_dc2_wdata,
    output logic            debug_store_dc3_valid,
    output logic [XLEN-1:0] debug_store_dc3_instr_tag,
    output logic [    31:0] debug_store_dc3_instr,
    output logic [XLEN-1:0] debug_store_dc3_addr,
    output logic [XLEN-1:0] debug_store_dc3_wdata
`endif
);

  logic dc1_by, dc1_half, dc1_word, dc1_load, dc1_store, dc1_unsign, dc1_legal;
  logic dc1_lsu_valid;
  logic dc1_unaligned_addr;
  logic [XLEN-1:0] dc1_rs1_data, dc1_rs2_data, dc1_imm;
  logic [XLEN-1:0] dc1_computed_addr;
  logic [     4:0] dc1_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc1_lane_id_q;

  logic dc2_by, dc2_half, dc2_word, dc2_load, dc2_store, dc2_unsign, dc2_legal;
  logic            dc2_lsu_valid;
  logic            dc2_unaligned_addr;
  logic [XLEN-1:0] dc2_computed_addr;
  logic [XLEN-1:0] dc2_load_buffer;
  logic [     4:0] dc2_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc2_lane_id_q;
  logic [XLEN-1:0] dc2_rs2_data;
  logic            dc2_fwd0_valid;
  logic [XLEN-1:0] dc2_fwd0_value;
  logic [     3:0] dc2_fwd0_strb;
  logic            dc2_fwd1_valid;
  logic [XLEN-1:0] dc2_fwd1_value;
  logic [     3:0] dc2_fwd1_strb;

  logic dc3_by, dc3_half, dc3_word, dc3_load, dc3_store, dc3_unsign, dc3_legal;
  logic                    dc3_unaligned_addr;
  logic [        XLEN-1:0] dc3_computed_addr;
  logic [        XLEN-1:0] dc3_load_buffer;
  logic [        XLEN-1:0] dc3_wb_data;
  logic [        XLEN-1:0] dc3_wb_data_mask;
  logic [        XLEN-1:0] dc3_wb_sext_mask;
  logic [             4:0] dc3_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc3_lane_id_q;

`ifdef TV_HAS_CORE_DEBUG
  logic [XLEN-1:0] dc1_lsu_instr_tag_out;
  logic [    31:0] dc1_lsu_instr_out;
  logic [XLEN-1:0] dc2_lsu_instr_tag_out;
  logic [    31:0] dc2_lsu_instr_out;
  logic [XLEN-1:0] dc3_lsu_instr_tag_out;
  logic [    31:0] dc3_lsu_instr_out;
`endif

  logic dc1_hold;

  /* ***** DC1 ***** */

  register_en_sync_rstn #(
      .WIDTH(7)
  ) lsu_ctrl_reg (
      .clk (clk),
      .rstn(rstn),
      .en  (~dc1_hold),
      .din ({
        engine_op.by,
        engine_op.half,
        engine_op.word,
        engine_op.load,
        engine_op.store,
        engine_op.unsign,
        engine_op.legal
      }),
      .dout({dc1_by, dc1_half, dc1_word, dc1_load, dc1_store, dc1_unsign, dc1_legal})
  );

  register_en_sync_rstn #(
      .WIDTH($bits({engine_op.rs1_data, engine_op.rs2_data, engine_op.imm, engine_op.rd_addr, engine_op.lane_id}))
  ) lsu_data_reg (
      .clk (clk),
      .rstn(rstn),
      .en  (~dc1_hold),
      .din ({engine_op.rs1_data, engine_op.rs2_data, engine_op.imm, engine_op.rd_addr, engine_op.lane_id}),
      .dout({dc1_rs1_data, dc1_rs2_data, dc1_imm, dc1_rd_addr, dc1_lane_id_q})
  );

`ifdef TV_HAS_CORE_DEBUG
  register_en_sync_rstn #(
      .WIDTH(XLEN)
  ) lsu_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .en  (~dc1_hold),
      .din (engine_op.instr_tag),
      .dout(dc1_lsu_instr_tag_out)
  );

  register_en_sync_rstn #(
      .WIDTH(32)
  ) lsu_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .en  (~dc1_hold),
      .din (engine_op.instr),
      .dout(dc1_lsu_instr_out)
  );
`endif

  assign dc1_lsu_valid = dc1_legal & (dc1_load | dc1_store);
  assign dc1_computed_addr = dc1_rs1_data + {{XLEN - 12{dc1_imm[11]}}, dc1_imm[11:0]};
  assign dc1_unaligned_addr = dc1_lsu_valid &
      lsu_is_unaligned(dc1_by, dc1_half, dc1_word, dc1_computed_addr[1:0]);

  logic [XLEN-1:0] dc1_word0_addr;
  logic [XLEN-1:0] dc1_word1_addr;
  logic [XLEN-1:0] dc2_word0_addr;
  logic [XLEN-1:0] dc2_word1_addr;
  logic [7:0] dc1_strb_wide;
  logic [3:0] dc1_load_strb0;
  logic [3:0] dc1_load_strb1;

  assign dc1_word0_addr = {dc1_computed_addr[XLEN-1:2], 2'b00};
  assign dc1_word1_addr = {dc1_computed_addr[XLEN-1:2] + 30'd1, 2'b00};
  assign dc1_strb_wide = lsu_strb_wide(dc1_by, dc1_half, dc1_word, dc1_computed_addr[1:0]);
  assign dc1_load_strb0 = dc1_strb_wide[3:0];
  assign dc1_load_strb1 = dc1_strb_wide[7:4];

  logic dc1_pipe_fwd0;
  logic dc1_pipe_fwd1;
  logic dc1_cam_fwd0;
  logic dc1_cam_fwd1;
  logic dc1_fwd0_valid;
  logic dc1_fwd1_valid;
  logic [XLEN-1:0] dc1_fwd0_value;
  logic [XLEN-1:0] dc1_fwd1_value;
  logic [3:0] dc1_fwd0_strb;
  logic [3:0] dc1_fwd1_strb;
  logic dc1_skip_read0;
  logic dc1_skip_read1;

  logic [7:0] dc2_strb_wide;
  logic [2*XLEN-1:0] dc2_store_wide;
  logic dc2_store_v;
  logic dc2_load_v;

  assign dc2_store_v = dc2_legal & dc2_store;
  assign dc2_load_v  = dc2_legal & dc2_load;
  assign dc2_word0_addr = {dc2_computed_addr[XLEN-1:2], 2'b00};
  assign dc2_word1_addr = {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00};
  assign dc2_strb_wide = lsu_strb_wide(dc2_by, dc2_half, dc2_word, dc2_computed_addr[1:0]);
  assign dc2_store_wide = lsu_store_data_wide(dc2_rs2_data, dc2_computed_addr[1:0]);

  /* Port conflict: unaligned op needs both TDP ports, older DC2 store wins. */
  assign engine_stall = (dc1_lsu_valid & dc1_load & dc2_store_v &
                         (dc1_unaligned_addr | dc2_unaligned_addr));
  assign dc1_hold = engine_stall;

  assign dc1_pipe_fwd0 = (dc1_load & dc1_legal) & dc2_store_v & (
      (dc2_word0_addr == dc1_word0_addr) |
      (dc2_unaligned_addr & (dc2_word1_addr == dc1_word0_addr))
  );
  assign dc1_pipe_fwd1 = (dc1_load & dc1_legal & dc1_unaligned_addr) & dc2_store_v & (
      (dc2_word0_addr == dc1_word1_addr) |
      (dc2_unaligned_addr & (dc2_word1_addr == dc1_word1_addr))
  );

  assign cam_lookup_valid   = dc1_load & dc1_lsu_valid;
  assign cam_lookup_addr    = dc1_word0_addr;
  assign cam_lookup_b_valid = dc1_load & dc1_lsu_valid & dc1_unaligned_addr;
  assign cam_lookup_b_addr  = dc1_word1_addr;
  assign dc1_cam_fwd0 = ext_forward_valid & dc1_load & dc1_lsu_valid;
  assign dc1_cam_fwd1 = ext_forward_b_valid & dc1_load & dc1_lsu_valid & dc1_unaligned_addr;

  assign dc1_fwd0_valid = dc1_pipe_fwd0 | dc1_cam_fwd0;
  assign dc1_fwd1_valid = dc1_pipe_fwd1 | dc1_cam_fwd1;

  assign dc1_fwd0_value = dc1_pipe_fwd0 ?
      ((dc2_word0_addr == dc1_word0_addr) ? dc2_store_wide[XLEN-1:0]
                                          : dc2_store_wide[2*XLEN-1:XLEN]) :
      ext_forward_value;
  assign dc1_fwd0_strb = dc1_pipe_fwd0 ?
      ((dc2_word0_addr == dc1_word0_addr) ? dc2_strb_wide[3:0] : dc2_strb_wide[7:4]) :
      ext_forward_strb;

  assign dc1_fwd1_value = dc1_pipe_fwd1 ?
      ((dc2_word0_addr == dc1_word1_addr) ? dc2_store_wide[XLEN-1:0]
                                          : dc2_store_wide[2*XLEN-1:XLEN]) :
      ext_forward_b_value;
  assign dc1_fwd1_strb = dc1_pipe_fwd1 ?
      ((dc2_word0_addr == dc1_word1_addr) ? dc2_strb_wide[3:0] : dc2_strb_wide[7:4]) :
      ext_forward_b_strb;

  assign dc1_skip_read0 = dc1_load & dc1_lsu_valid & dc1_fwd0_valid &
      lsu_strb_covers(dc1_load_strb0, dc1_fwd0_strb);
  assign dc1_skip_read1 = dc1_load & dc1_lsu_valid & dc1_unaligned_addr & dc1_fwd1_valid &
      lsu_strb_covers(dc1_load_strb1, dc1_fwd1_strb);

  logic dc2_in_legal;
  logic dc2_in_lsu_valid;
  assign dc2_in_legal     = dc1_legal & ~engine_stall;
  assign dc2_in_lsu_valid = dc1_lsu_valid & ~engine_stall;

  /* ****** DC2 ***** */
  register_sync_rstn #(
      .WIDTH($bits(
          {
            dc2_by,
            dc2_half,
            dc2_word,
            dc2_load,
            dc2_store,
            dc2_unsign,
            dc2_legal,
            dc2_unaligned_addr,
            dc1_computed_addr,
            dc1_rd_addr,
            dc1_lane_id_q,
            dc2_lsu_valid,
            dc1_rs2_data,
            dc1_fwd0_valid,
            dc1_fwd0_value,
            dc1_fwd0_strb,
            dc1_fwd1_valid,
            dc1_fwd1_value,
            dc1_fwd1_strb
          }
      ))
  ) dc2_dccm_rdata_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
        dc1_by,
        dc1_half,
        dc1_word,
        dc1_load,
        dc1_store,
        dc1_unsign,
        dc2_in_legal,
        dc1_unaligned_addr,
        dc1_computed_addr,
        dc1_rd_addr,
        dc1_lane_id_q,
        dc2_in_lsu_valid,
        dc1_rs2_data,
        dc1_fwd0_valid,
        dc1_fwd0_value,
        dc1_fwd0_strb,
        dc1_fwd1_valid,
        dc1_fwd1_value,
        dc1_fwd1_strb
      }),
      .dout({
        dc2_by,
        dc2_half,
        dc2_word,
        dc2_load,
        dc2_store,
        dc2_unsign,
        dc2_legal,
        dc2_unaligned_addr,
        dc2_computed_addr,
        dc2_rd_addr,
        dc2_lane_id_q,
        dc2_lsu_valid,
        dc2_rs2_data,
        dc2_fwd0_valid,
        dc2_fwd0_value,
        dc2_fwd0_strb,
        dc2_fwd1_valid,
        dc2_fwd1_value,
        dc2_fwd1_strb
      })
  );

`ifdef TV_HAS_CORE_DEBUG
  register_sync_rstn #(
      .WIDTH(XLEN)
  ) dc2_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc1_lsu_instr_tag_out),
      .dout(dc2_lsu_instr_tag_out)
  );

  register_sync_rstn #(
      .WIDTH(32)
  ) dc2_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc1_lsu_instr_out),
      .dout(dc2_lsu_instr_out)
  );
`endif

  logic [XLEN-1:0] dc2_merged_word0;
  logic [XLEN-1:0] dc2_merged_word1;
  logic [2*XLEN-1:0] dc2_load_wide;

  assign dc2_merged_word0 = dc2_fwd0_valid ?
      lsu_merge_bytes(dccm_rdata[0], dc2_fwd0_value, dc2_fwd0_strb) :
      dccm_rdata[0];
  assign dc2_merged_word1 = dc2_fwd1_valid ?
      lsu_merge_bytes(dccm_rdata[1], dc2_fwd1_value, dc2_fwd1_strb) :
      dccm_rdata[1];
  logic [2*XLEN-1:0] dc2_load_shifted;
  assign dc2_load_wide = {dc2_merged_word1, dc2_merged_word0};
  assign dc2_load_shifted = dc2_load_wide >> {dc2_computed_addr[1:0], 3'b000};
  assign dc2_load_buffer = dc2_load_shifted[XLEN-1:0];

  /* ****** DC3 ***** */
  register_sync_rstn #(
      .WIDTH($bits(
          {
            dc3_load_buffer,
            dc3_unaligned_addr,
            dc3_computed_addr,
            dc3_by,
            dc3_half,
            dc3_word,
            dc3_load,
            dc3_store,
            dc3_unsign,
            dc3_legal,
            dc3_rd_addr,
            dc3_lane_id_q
          }
      ))
  ) dc3_dccm_rdata_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
        dc2_load_buffer,
        dc2_unaligned_addr,
        dc2_computed_addr,
        dc2_by,
        dc2_half,
        dc2_word,
        dc2_load,
        dc2_store,
        dc2_unsign,
        dc2_legal,
        dc2_rd_addr,
        dc2_lane_id_q
      }),
      .dout({
        dc3_load_buffer,
        dc3_unaligned_addr,
        dc3_computed_addr,
        dc3_by,
        dc3_half,
        dc3_word,
        dc3_load,
        dc3_store,
        dc3_unsign,
        dc3_legal,
        dc3_rd_addr,
        dc3_lane_id_q
      })
  );

`ifdef TV_HAS_CORE_DEBUG
  register_sync_rstn #(
      .WIDTH(XLEN)
  ) dc3_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc2_lsu_instr_tag_out),
      .dout(dc3_lsu_instr_tag_out)
  );

  register_sync_rstn #(
      .WIDTH(32)
  ) dc3_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .din (dc2_lsu_instr_out),
      .dout(dc3_lsu_instr_out)
  );
`endif

  assign dc3_wb_data = dc3_load_buffer;
  assign dc3_wb_sext_mask = ({{XLEN-8{dc3_by & ~dc3_unsign & dc3_wb_data[7]}} & 24'hFFFFFF, 8'h00}) |
                            ({{XLEN-16{dc3_half & ~dc3_unsign & dc3_wb_data[15]}} & 16'hFFFF, 16'h0000});
  assign dc3_wb_data_mask = ({XLEN{dc3_by}} & 32'h000000FF) |
                            ({XLEN{dc3_half}} & 32'h0000FFFF) |
                            ({XLEN{dc3_word}} & 32'hFFFFFFFF);

  /* Port 0: beat-0 read, unaligned-store beat 1 write.
   * Port 1: beat-0 write, unaligned-load beat 1 read. */
  assign dccm_raddr[0]     = dc1_word0_addr;
  assign dccm_rvalid_in[0] = dc1_lsu_valid & dc1_load & ~dc1_skip_read0 & ~engine_stall;
  assign dccm_waddr[0]     = dc2_word1_addr;
  assign dccm_wen[0]       = dc2_store_v & dc2_unaligned_addr;
  assign dccm_wdata[0]     = dc2_store_wide[2*XLEN-1:XLEN];
  assign dccm_wstrb[0]     = dc2_strb_wide[7:4];

  assign dccm_raddr[1]     = dc1_word1_addr;
  assign dccm_rvalid_in[1] = dc1_lsu_valid & dc1_load & dc1_unaligned_addr & ~dc1_skip_read1 &
                             ~engine_stall;
  assign dccm_waddr[1]     = dc2_word0_addr;
  assign dccm_wen[1]       = dc2_store_v;
  assign dccm_wdata[1]     = dc2_store_wide[XLEN-1:0];
  assign dccm_wstrb[1]     = dc2_strb_wide[3:0];

  /* sv2v flattens unpacked ports; Yosys rejects them in a reg initializer. */
  logic unused_rvalid;
  assign unused_rvalid = dccm_rvalid_out[0] | dccm_rvalid_out[1];

  assign wb_rd_wr_en = dc3_load & dc3_legal;
  assign wb_rd_addr  = dc3_rd_addr;
  assign wb_lane_id  = dc3_lane_id_q;
  assign wb_data     = (dc3_wb_data & dc3_wb_data_mask) | dc3_wb_sext_mask;

  assign engine_busy  = dc1_lsu_valid | dc2_lsu_valid;

  assign dc1_lane_id    = dc1_lane_id_q;
  assign dc1_lane_valid = dc1_lsu_valid;
  assign dc2_lane_id    = dc2_lane_id_q;
  assign dc2_lane_valid = dc2_lsu_valid;

  assign store_retire_valid = dc2_store_v;
  assign store_retire_addr  = dc2_computed_addr;
  assign store_retire_line_clear_valid = dc2_store_v;
  assign store_retire_line_clear_addr  = dc2_word0_addr;
  assign store_retire_line_clear_b_valid = dc2_store_v & dc2_unaligned_addr;
  assign store_retire_line_clear_b_addr  = dc2_word1_addr;

  assign store_cam_fill_valid = dc2_store_v;
  assign store_cam_fill_addr  = dc2_computed_addr;
  assign store_cam_fill_data  = dc2_store_wide[XLEN-1:0];
  assign store_cam_fill_strb  = dc2_strb_wide[3:0];
  assign store_cam_fill_b_valid = dc2_store_v & dc2_unaligned_addr;
  assign store_cam_fill_b_addr  = dc2_word1_addr;
  assign store_cam_fill_b_data  = dc2_store_wide[2*XLEN-1:XLEN];
  assign store_cam_fill_b_strb  = dc2_strb_wide[7:4];

`ifdef TV_HAS_CORE_DEBUG
  assign instr_tag_out = dc3_lsu_instr_tag_out;
  assign instr_out     = dc3_lsu_instr_out;

  assign debug_store_dc2_valid     = dc2_store_v;
  assign debug_store_dc2_instr_tag = dc2_lsu_instr_tag_out;
  assign debug_store_dc2_instr     = dc2_lsu_instr_out;
  assign debug_store_dc2_addr      = dc2_computed_addr;
  assign debug_store_dc2_wdata     = (dc2_store_wide[XLEN-1:0] >> {dc2_computed_addr[1:0], 3'b000}) &
                                     (({XLEN{dc2_by}} & 32'h000000FF) |
                                      ({XLEN{dc2_half}} & 32'h0000FFFF) |
                                      ({XLEN{dc2_word}} & 32'hFFFFFFFF));

  assign debug_store_dc3_valid     = dc2_store_v & dc2_unaligned_addr;
  assign debug_store_dc3_instr_tag = dc2_lsu_instr_tag_out;
  assign debug_store_dc3_instr     = dc2_lsu_instr_out;
  assign debug_store_dc3_addr      = dc2_computed_addr;
  assign debug_store_dc3_wdata     = dc2_store_wide[2*XLEN-1:XLEN] &
                                     (({XLEN{dc2_by}} & 32'h000000FF) |
                                      ({XLEN{dc2_half}} & 32'h0000FFFF) |
                                      ({XLEN{dc2_word}} & 32'hFFFFFFFF));
`endif

endmodule
