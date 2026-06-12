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

module lsu_engine (
    input logic clk,
    input logic rstn,

    /* Dispatch Interface */
    input  lsu_mem_op_t engine_op,
    input  logic        ext_forward_valid,
    input  logic [XLEN-1:0] ext_forward_value,
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
    output logic            store_cam_fill_valid,
    output logic [XLEN-1:0] store_cam_fill_addr,
    output logic [XLEN-1:0] store_cam_fill_data,

    /* DCCM Interface */
    output logic [XLEN-1:0] dccm_raddr,
    output logic            dccm_rvalid_in,
    input  logic [XLEN-1:0] dccm_rdata,
    input  logic            dccm_rvalid_out,
    output logic [XLEN-1:0] dccm_waddr,
    output logic            dccm_wen,
    output logic [XLEN-1:0] dccm_wdata
`ifndef SYNTHESIS
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
  logic            dc1_store_needs_load;
  logic            dc1_pipeline_forward;
  logic            dc1_cam_forward;
  logic            dc1_any_forward;
  logic [XLEN-1:0] dc1_forward_value;

  logic dc2_by, dc2_half, dc2_word, dc2_load, dc2_store, dc2_unsign, dc2_legal;
  logic            dc2_lsu_valid;
  logic            dc2_unaligned_addr;
  logic [XLEN-1:0] dc2_computed_addr;
  logic [XLEN-1:0] dc2_load_buffer;
  logic [     4:0] dc2_rd_addr;
  logic [LSU_LANE_ID_WIDTH-1:0] dc2_lane_id_q;
  logic [XLEN-1:0] dc2_rs2_data;
  logic            dc2_store_needs_load;
  logic            dc2_store_forward;
  logic [XLEN-1:0] dc2_forward_value;
  logic            dc2_store_forward_next;
  logic [XLEN-1:0] dc2_forward_value_next;

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

`ifndef SYNTHESIS
  logic [XLEN-1:0] dc1_lsu_instr_tag_out;
  logic [    31:0] dc1_lsu_instr_out;
  logic [XLEN-1:0] dc2_lsu_instr_tag_out;
  logic [    31:0] dc2_lsu_instr_out;
  logic [XLEN-1:0] dc3_lsu_instr_tag_out;
  logic [    31:0] dc3_lsu_instr_out;
`endif
  logic [        XLEN-1:0] dc3_store_buffer;
  logic                    dc3_store_forward;
  logic [        XLEN-1:0] dc3_forward_value;

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

`ifndef SYNTHESIS
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
  assign dc1_store_needs_load = dc1_store & (dc1_by | dc1_half | dc1_word & dc1_unaligned_addr);

  assign dc1_pipeline_forward = ((dc1_store | dc1_load) & dc1_legal) & (dc2_store & dc2_legal) &
      (dccm_waddr[XLEN-1:0] == {dc1_computed_addr[XLEN-1:2], 2'b00});
  assign dc1_cam_forward = ext_forward_valid & ((dc1_store | dc1_load) & dc1_legal);
  assign dc1_any_forward = dc1_pipeline_forward | dc1_cam_forward;
  assign dc1_forward_value = dc1_pipeline_forward ? dccm_wdata : ext_forward_value;

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
            dc1_store_needs_load,
            dc1_rs2_data,
            dc1_any_forward,
            dc1_forward_value
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
        dc1_store_needs_load,
        dc1_rs2_data,
        dc1_any_forward,
        dc1_forward_value
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
        dc2_store_needs_load,
        dc2_rs2_data,
        dc2_store_forward,
        dc2_forward_value
      })
  );

`ifndef SYNTHESIS
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

  logic [2*XLEN-1:0] dc2_store_mask_base;
  logic [2*XLEN-1:0] dc2_store_mask;
  logic [2*XLEN-1:0] dc2_store_buffer;

  assign dc2_store_mask_base = {2*XLEN{dc2_by}} & 64'h00000000000000FF |
                               {2*XLEN{dc2_half}} & 64'h000000000000FFFF |
                               {2*XLEN{dc2_word}} & 64'h00000000FFFFFFFF;

  assign dc2_store_mask = dc2_store_mask_base << {dc2_computed_addr[1:0], 3'b000};

  assign dc2_store_buffer = (dc2_store_forward) ?
      (({{XLEN{1'b0}}, dc2_rs2_data} & dc2_store_mask_base) << {dc2_computed_addr[1:0], 3'b000}) |
      ({{XLEN{1'b0}}, dc2_forward_value} & ~dc2_store_mask) :
      (({{XLEN{1'b0}}, dc2_rs2_data} & dc2_store_mask_base) << {dc2_computed_addr[1:0], 3'b000}) |
      ({{XLEN{1'b0}}, dccm_rdata} & ~dc2_store_mask);

  assign dc2_store_forward_next = ((dc2_store | dc2_load) & dc2_legal & dc2_unaligned_addr) &
      (dc3_store & dc3_legal) &
      (dccm_waddr[XLEN-1:0] == {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00});
  assign dc2_forward_value_next = dccm_wdata;

  assign dc2_load_buffer = (dc2_store_forward) ? dc2_forward_value >> {dc2_computed_addr[1:0], 3'b000} :
                                                 dccm_rdata >> {dc2_computed_addr[1:0], 3'b000};

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
            dc3_store_forward,
            dc3_forward_value
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
        dc2_store_forward_next,
        dc2_forward_value_next
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
        dc3_store_forward,
        dc3_forward_value
      })
  );

`ifndef SYNTHESIS
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

  assign dc3_wb_data = ({XLEN{~dc3_unaligned_addr & ~dc3_store_forward}} & dc3_load_buffer) |
                       ({XLEN{dc3_unaligned_addr & ~dc3_store_forward}} &
                        (dc3_load_buffer | (dccm_rdata << dc3_shamt))) |
                       ({XLEN{~dc3_unaligned_addr & dc3_store_forward}} & dc3_forward_value) |
                       ({XLEN{dc3_unaligned_addr & dc3_store_forward}} &
                        (dc3_load_buffer | (dc3_forward_value << dc3_shamt)));

  assign dc3_wb_sext_mask = ({{XLEN-8{dc3_by & ~dc3_unsign & dc3_wb_data[7]}} & 24'hFFFFFF, 8'h00}) |
                            ({{XLEN-16{dc3_half & ~dc3_unsign & dc3_wb_data[15]}} & 16'hFFFF, 16'h0000});

  assign dc3_wb_data_mask = ({XLEN{dc3_by}} & 32'h000000FF) |
                            ({XLEN{dc3_half}} & 32'h0000FFFF) |
                            ({XLEN{dc3_word}} & 32'hFFFFFFFF);

  assign dc3_store_buffer = (dc3_store_forward) ?
      (dc3_rs2_data >> dc3_shamt) | (dc3_forward_value & ~(dc3_wb_data_mask << dc3_shamt)) :
      (dc3_rs2_data >> dc3_shamt) | (dccm_rdata & ~(dc3_wb_data_mask << dc3_shamt));

  assign dccm_raddr = ({XLEN{dc1_lsu_valid & (dc1_load | dc1_store_needs_load) & ~dc2_unaligned_addr}} &
                       {dc1_computed_addr[XLEN-1:2], 2'b00}) |
                      ({XLEN{dc2_lsu_valid & (dc2_load | dc2_store_needs_load) & dc2_unaligned_addr}} &
                       {dc2_computed_addr[XLEN-1:2] + 30'd1, 2'b00});

  assign dccm_rvalid_in = (dc1_lsu_valid & ~dc2_unaligned_addr & ~dc1_any_forward) |
                          (dc2_lsu_valid & dc2_unaligned_addr & ~dc2_store_forward);

  assign dccm_waddr = ({XLEN{dc2_legal & dc2_store & ~dc3_unaligned_addr}} &
                       {dc2_computed_addr[XLEN-1:2], 2'b00}) |
                      ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} &
                       {dc3_computed_addr[XLEN-1:2] + 30'd1, 2'b00});

  assign dccm_wen = (dc2_legal & dc2_store) | (dc3_legal & dc3_store & dc3_unaligned_addr);

  assign dccm_wdata = ({XLEN{dc2_legal & dc2_store & ~dc3_unaligned_addr}} & dc2_store_buffer[XLEN-1:0]) |
                      ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} & dc3_store_buffer);

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

  assign store_retire_valid = (dc2_legal & dc2_store & ~dc2_unaligned_addr) |
                              (dc3_legal & dc3_store & dc3_unaligned_addr);
  assign store_retire_addr  = ({XLEN{dc2_legal & dc2_store & ~dc2_unaligned_addr}} & dc2_computed_addr) |
                              ({XLEN{dc3_legal & dc3_store & dc3_unaligned_addr}} & dc3_computed_addr);

  assign store_cam_fill_valid = dc2_legal & dc2_store;
  assign store_cam_fill_addr  = dc2_computed_addr;
  assign store_cam_fill_data  = dc2_store_buffer[XLEN-1:0];

`ifndef SYNTHESIS
  assign instr_tag_out = dc3_lsu_instr_tag_out;
  assign instr_out     = dc3_lsu_instr_out;

  assign debug_store_dc2_valid     = dc2_legal & dc2_store;
  assign debug_store_dc2_instr_tag = dc2_lsu_instr_tag_out;
  assign debug_store_dc2_instr     = dc2_lsu_instr_out;
  assign debug_store_dc2_addr      = dc2_computed_addr;
  assign debug_store_dc2_wdata     = (dc2_store_buffer[XLEN-1:0] >> {dc2_computed_addr[1:0], 3'b000}) &
                                     dc2_store_mask_base[XLEN-1:0];

  assign debug_store_dc3_valid     = dc3_legal & dc3_store & dc3_unaligned_addr;
  assign debug_store_dc3_instr_tag = dc3_lsu_instr_tag_out;
  assign debug_store_dc3_instr     = dc3_lsu_instr_out;
  assign debug_store_dc3_addr      = dc3_computed_addr;
  assign debug_store_dc3_wdata     = dc3_store_buffer[XLEN-1:0] & dc3_wb_data_mask[XLEN-1:0];
`endif

endmodule
