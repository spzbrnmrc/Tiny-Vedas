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
//           _____
//          /\    \
//         /::\    \
//        /::::\    \
//       /::::::\    \
//      /:::/\:::\    \
//     /:::/__\:::\    \            Vendor      : Siliscale
//     \:::\   \:::\    \           Version     : 2025.1
//   ___\:::\   \:::\    \          Description : Tiny Vedas - LSU Engine
//  /\   \:::\   \:::\    \
// /::\   \:::\   \:::\____\
// \:::\   \:::\   \::/    /
//  \:::\   \:::\   \/____/
//   \:::\   \:::\    \
//    \:::\   \:::\____\
//     \:::\  /:::/    /
//      \:::\/:::/    /
//       \::::::/    /
//        \::::/    /
//         \::/    /
//          \/____/
///////////////////////////////////////////////////////////////////////////////

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
    output logic        cam_lookup_valid,
    output logic [XLEN-1:0] cam_lookup_addr,
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

    /* DCCM Interface */
    output logic [XLEN-1:0] dccm_raddr,
    output logic            dccm_rvalid_in,
    input  logic [XLEN-1:0] dccm_rdata,
    input  logic            dccm_rvalid_out,
    output logic [XLEN-1:0] dccm_waddr,
    output logic            dccm_wen,
    output logic [XLEN-1:0] dccm_wdata,
    output logic [     3:0] dccm_wstrb
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
  logic engine_stall_q;
  logic dc1_lsu_valid;
  logic dc1_unaligned_addr;
  logic [XLEN-1:0] dc1_rs1_data, dc1_rs2_data, dc1_imm;
  logic [XLEN-1:0] dc1_computed_addr;
  logic [     4:0] dc1_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc1_lane_id_q;
  logic            dc1_pipeline_forward;
  logic            dc1_cam_forward;
  logic            dc1_any_forward;
  logic            dc1_skip_read;
  logic [XLEN-1:0] dc1_forward_value;
  logic [     3:0] dc1_forward_strb;
  logic [     7:0] dc1_strb_wide;
  logic [     3:0] dc1_load_strb0;

  logic dc2_by, dc2_half, dc2_word, dc2_load, dc2_store, dc2_unsign, dc2_legal;
  logic            dc2_lsu_valid;
  logic            dc2_unaligned_addr;
  logic [XLEN-1:0] dc2_computed_addr;
  logic [XLEN-1:0] dc2_load_buffer;
  logic [     4:0] dc2_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc2_lane_id_q;
  logic [XLEN-1:0] dc2_rs2_data;
  logic            dc2_fwd_valid;
  logic [XLEN-1:0] dc2_forward_value;
  logic [     3:0] dc2_forward_strb;
  logic            dc2_fwd_valid_next;
  logic [XLEN-1:0] dc2_forward_value_next;
  logic [     3:0] dc2_forward_strb_next;

  logic dc3_by, dc3_half, dc3_word, dc3_load, dc3_store, dc3_unsign, dc3_legal;
  logic                    dc3_unaligned_addr;
  logic [        XLEN-1:0] dc3_computed_addr;
  logic [        XLEN-1:0] dc3_load_buffer;
  logic [        XLEN-1:0] dc3_wb_data;
  logic [        XLEN-1:0] dc3_wb_data_mask;
  logic [        XLEN-1:0] dc3_wb_sext_mask;
  logic [             4:0] dc3_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc3_lane_id_q;
  logic [$clog2(XLEN)-1:0] dc3_shamt;
  logic [             2:0] dc3_shamt_by;
  logic [        XLEN-1:0] dc3_rs2_data;

`ifdef TV_HAS_CORE_DEBUG
  logic [XLEN-1:0] dc1_lsu_instr_tag_out;
  logic [    31:0] dc1_lsu_instr_out;
  logic [XLEN-1:0] dc2_lsu_instr_tag_out;
  logic [    31:0] dc2_lsu_instr_out;
  logic [XLEN-1:0] dc3_lsu_instr_tag_out;
  logic [    31:0] dc3_lsu_instr_out;
`endif
  logic [        XLEN-1:0] dc3_store_buffer;
  logic                    dc3_fwd_valid;
  logic [        XLEN-1:0] dc3_forward_value;
  logic [             3:0] dc3_forward_strb;

  /* ***** DC1 ***** */

  register_sync_rstn #(
      .WIDTH(7)
  ) lsu_ctrl_reg (
      .clk(clk),
      .rstn(rstn),
      .din({
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

  register_sync_rstn #(
      .WIDTH($bits({engine_op.rs1_data, engine_op.rs2_data, engine_op.imm, engine_op.rd_addr, engine_op.lane_id}))
  ) lsu_data_reg (
      .clk (clk),
      .rstn(rstn),
      .din ({engine_op.rs1_data, engine_op.rs2_data, engine_op.imm, engine_op.rd_addr, engine_op.lane_id}),
      .dout({dc1_rs1_data, dc1_rs2_data, dc1_imm, dc1_rd_addr, dc1_lane_id_q})
  );

`ifdef TV_HAS_CORE_DEBUG
  register_sync_rstn #(
      .WIDTH(XLEN)
  ) lsu_instr_tag_reg (
      .clk (clk),
      .rstn(rstn),
      .din (engine_op.instr_tag),
      .dout(dc1_lsu_instr_tag_out)
  );

  register_sync_rstn #(
      .WIDTH(32)
  ) lsu_instr_out_reg (
      .clk (clk),
      .rstn(rstn),
      .din (engine_op.instr),
      .dout(dc1_lsu_instr_out)
  );
`endif

  assign dc1_lsu_valid = dc1_legal & (dc1_load | dc1_store);
  assign dc1_computed_addr = dc1_rs1_data + {{XLEN - 12{dc1_imm[11]}}, dc1_imm[11:0]};

  assign dc1_unaligned_addr = engine_stall_q ? 'b0 :
      (|dc1_computed_addr[1:0] & dc1_word) | (&dc1_computed_addr[1:0] & dc1_half);

  assign dc1_strb_wide = lsu_strb_wide(dc1_by, dc1_half, dc1_word, dc1_computed_addr[1:0]);
  assign dc1_load_strb0 = dc1_strb_wide[3:0];

  /* Word-aligned compare; do not reuse dccm_waddr (write mux cone). */
  assign dc1_pipeline_forward = (dc1_load & dc1_legal) & (
      ((dc2_store & dc2_legal) &
       ({dc2_computed_addr[XLEN-1:2], 2'b00} == {dc1_computed_addr[XLEN-1:2], 2'b00})) |
      ((dc3_store & dc3_legal & dc3_unaligned_addr) &
       ({dc3_computed_addr[XLEN-1:2] + 30'd1, 2'b00} == {dc1_computed_addr[XLEN-1:2], 2'b00}))
  );
  assign dc1_cam_forward = ext_forward_valid & dc1_load & dc1_lsu_valid;
  assign cam_lookup_valid = dc1_load & dc1_lsu_valid;
  assign cam_lookup_addr  = dc1_computed_addr;
  assign dc1_any_forward = dc1_pipeline_forward | dc1_cam_forward;
  assign dc1_forward_value = dc1_pipeline_forward ? dccm_wdata : ext_forward_value;
  assign dc1_forward_strb  = dc1_pipeline_forward ? dccm_wstrb : ext_forward_strb;
  assign dc1_skip_read = dc1_load & dc1_lsu_valid & dc1_any_forward &
      lsu_strb_covers(dc1_load_strb0, dc1_forward_strb);

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
            dc1_any_forward,
            dc1_forward_value,
            dc1_forward_strb
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
        dc1_legal,
        dc1_unaligned_addr,
        dc1_computed_addr,
        dc1_rd_addr,
        dc1_lane_id_q,
        dc1_lsu_valid,
        dc1_rs2_data,
        dc1_any_forward,
        dc1_forward_value,
        dc1_forward_strb
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
        dc2_fwd_valid,
        dc2_forward_value,
        dc2_forward_strb
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

  logic [7:0] dc2_strb_wide;
  logic [2*XLEN-1:0] dc2_store_buffer;
  logic [XLEN-1:0] dc2_merged_word;

  assign dc2_strb_wide = lsu_strb_wide(dc2_by, dc2_half, dc2_word, dc2_computed_addr[1:0]);
  assign dc2_store_buffer = lsu_store_data_wide(dc2_rs2_data, dc2_computed_addr[1:0]);

  assign dc2_merged_word = dc2_fwd_valid ?
      lsu_merge_bytes(dccm_rdata, dc2_forward_value, dc2_forward_strb) :
      dccm_rdata;

  assign dc2_fwd_valid_next = (dc2_load & dc2_legal & dc2_unaligned_addr) &
      (dc3_store & dc3_legal & dc3_unaligned_addr) &
      ({dc3_computed_addr[XLEN-1:2] + 30'd1, 2'b00} ==
       {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00});
  assign dc2_forward_value_next = dccm_wdata;
  assign dc2_forward_strb_next  = dccm_wstrb;

  assign dc2_load_buffer = dc2_merged_word >> {dc2_computed_addr[1:0], 3'b000};

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
            dc3_lane_id_q,
            dc3_rs2_data,
            dc3_fwd_valid,
            dc3_forward_value,
            dc3_forward_strb
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
        dc2_lane_id_q,
        dc2_rs2_data,
        dc2_fwd_valid_next,
        dc2_forward_value_next,
        dc2_forward_strb_next
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
        dc3_lane_id_q,
        dc3_rs2_data,
        dc3_fwd_valid,
        dc3_forward_value,
        dc3_forward_strb
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

  register_sync_rstn #(
      .WIDTH(1)
  ) stall_reg (
      .clk (clk),
      .rstn(rstn),
      .din (engine_stall),
      .dout(engine_stall_q)
  );

  assign dc3_shamt_by = (3'd4 - {1'd0, dc3_computed_addr[1:0]});
  assign dc3_shamt = {dc3_shamt_by[1:0], 3'b000};

  logic [7:0] dc3_strb_wide;
  logic [2*XLEN-1:0] dc3_store_data_wide;
  logic [XLEN-1:0] dc3_beat1_word;
  logic [3:0] dc2_load_strb1;
  logic dc2_skip_read1;

  assign dc3_strb_wide = lsu_strb_wide(dc3_by, dc3_half, dc3_word, dc3_computed_addr[1:0]);
  assign dc3_store_data_wide = lsu_store_data_wide(dc3_rs2_data, dc3_computed_addr[1:0]);
  assign dc3_store_buffer = dc3_store_data_wide[2*XLEN-1:XLEN];

  assign dc3_beat1_word = dc3_fwd_valid ?
      lsu_merge_bytes(dccm_rdata, dc3_forward_value, dc3_forward_strb) :
      dccm_rdata;

  assign dc3_wb_data = dc3_unaligned_addr ?
      (dc3_load_buffer | (dc3_beat1_word << dc3_shamt)) :
      dc3_load_buffer;

  assign dc3_wb_sext_mask = ({{XLEN-8{dc3_by & ~dc3_unsign & dc3_wb_data[7]}} & 24'hFFFFFF, 8'h00}) |
                            ({{XLEN-16{dc3_half & ~dc3_unsign & dc3_wb_data[15]}} & 16'hFFFF, 16'h0000});

  assign dc3_wb_data_mask = ({XLEN{dc3_by}} & 32'h000000FF) |
                            ({XLEN{dc3_half}} & 32'h0000FFFF) |
                            ({XLEN{dc3_word}} & 32'hFFFFFFFF);

  assign dc2_load_strb1 = dc2_strb_wide[7:4];
  assign dc2_skip_read1 = dc2_load & dc2_lsu_valid & dc2_unaligned_addr & dc2_fwd_valid_next &
      lsu_strb_covers(dc2_load_strb1, dc2_forward_strb_next);

  assign dccm_raddr = ({XLEN{dc1_lsu_valid & dc1_load & ~dc2_unaligned_addr}} &
                       {dc1_computed_addr[XLEN-1:2], 2'b00}) |
                      ({XLEN{dc2_lsu_valid & dc2_load & dc2_unaligned_addr}} &
                       {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00});

  assign dccm_rvalid_in = (dc1_lsu_valid & dc1_load & ~dc2_unaligned_addr & ~dc1_skip_read) |
                          (dc2_lsu_valid & dc2_load & dc2_unaligned_addr & ~dc2_skip_read1);

  assign dccm_waddr = ({XLEN{dc2_legal & dc2_store & ~dc3_unaligned_addr}} &
                       {dc2_computed_addr[XLEN-1:2], 2'b00}) |
                      ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} &
                       {dc3_computed_addr[XLEN-1:2] + 30'd1, 2'b00});

  assign dccm_wen = (dc2_legal & dc2_store) | (dc3_legal & dc3_store & dc3_unaligned_addr);

  assign dccm_wdata = ({XLEN{dc2_legal & dc2_store & ~dc3_unaligned_addr}} & dc2_store_buffer[XLEN-1:0]) |
                      ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} & dc3_store_buffer);

  assign dccm_wstrb = ({4{dc2_legal & dc2_store & ~dc3_unaligned_addr}} & dc2_strb_wide[3:0]) |
                      ({4{dc3_legal & dc3_store & dc3_unaligned_addr}} & dc3_strb_wide[7:4]);

  assign wb_rd_wr_en = dc3_load & dc3_legal;
  assign wb_rd_addr  = dc3_rd_addr;
  assign wb_lane_id  = dc3_lane_id_q;
  assign wb_data     = (dc3_wb_data & dc3_wb_data_mask) | dc3_wb_sext_mask;

  assign engine_stall = dc1_unaligned_addr;
  assign engine_busy  = dc1_lsu_valid | dc2_lsu_valid;

  assign dc1_lane_id    = dc1_lane_id_q;
  assign dc1_lane_valid = dc1_lsu_valid;
  assign dc2_lane_id    = dc2_lane_id_q;
  assign dc2_lane_valid = dc2_lsu_valid;

  logic store_retire_unaligned;

  assign store_retire_unaligned = dc3_legal & dc3_store & dc3_unaligned_addr;
  assign store_retire_valid = (dc2_legal & dc2_store & ~dc2_unaligned_addr) | store_retire_unaligned;
  assign store_retire_addr  = ({XLEN{dc2_legal & dc2_store & ~dc2_unaligned_addr}} & dc2_computed_addr) |
                              ({XLEN{store_retire_unaligned}} & dc3_computed_addr);

  /* Unaligned stores touch two aligned lines; clear both CAM slots on retire. */
  assign store_retire_line_clear_valid = store_retire_unaligned;
  assign store_retire_line_clear_addr  = {dc3_computed_addr[XLEN-1:2], 2'b00};
  assign store_retire_line_clear_b_valid = store_retire_unaligned;
  assign store_retire_line_clear_b_addr  = {dc3_computed_addr[XLEN-1:2] + 30'd1, 2'b00};

  assign store_cam_fill_valid = dc2_legal & dc2_store;
  assign store_cam_fill_addr  = dc2_computed_addr;
  assign store_cam_fill_data  = dc2_store_buffer[XLEN-1:0];
  assign store_cam_fill_strb  = dc2_strb_wide[3:0];

`ifdef TV_HAS_CORE_DEBUG
  assign instr_tag_out = dc3_lsu_instr_tag_out;
  assign instr_out     = dc3_lsu_instr_out;

  assign debug_store_dc2_valid     = dc2_legal & dc2_store;
  assign debug_store_dc2_instr_tag = dc2_lsu_instr_tag_out;
  assign debug_store_dc2_instr     = dc2_lsu_instr_out;
  assign debug_store_dc2_addr      = dc2_computed_addr;
  assign debug_store_dc2_wdata     = (dc2_store_buffer[XLEN-1:0] >> {dc2_computed_addr[1:0], 3'b000}) &
                                     (({XLEN{dc2_by}} & 32'h000000FF) |
                                      ({XLEN{dc2_half}} & 32'h0000FFFF) |
                                      ({XLEN{dc2_word}} & 32'hFFFFFFFF));

  assign debug_store_dc3_valid     = dc3_legal & dc3_store & dc3_unaligned_addr;
  assign debug_store_dc3_instr_tag = dc3_lsu_instr_tag_out;
  assign debug_store_dc3_instr     = dc3_lsu_instr_out;
  assign debug_store_dc3_addr      = dc3_computed_addr;
  assign debug_store_dc3_wdata     = dc3_store_buffer[XLEN-1:0] & dc3_wb_data_mask[XLEN-1:0];
`endif

endmodule
