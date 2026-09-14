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
//   ___\:::\   \:::\    \          Description : Tiny Vedas - Central LSU
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

module lsu_top #(
    parameter int REQ_PORT_COUNT  = ISSUE_WIDTH,
    parameter int DCCM_PORT_COUNT = LSU_DCCM_PORT_COUNT,
    parameter int LOAD_QUEUE_DEPTH  = LSU_LOAD_QUEUE_DEPTH,
    parameter int STORE_QUEUE_DEPTH = LSU_STORE_QUEUE_DEPTH
) (
    input logic clk,
    input logic rstn,

    /* Per-lane request ports from EXU */
    input  idu1_out_t                 req_ctrl   [REQ_PORT_COUNT-1:0],
    input  logic                      req_valid  [REQ_PORT_COUNT-1:0],
    output logic                      req_ready  [REQ_PORT_COUNT-1:0],

    /* Per-lane load responses and status */
    output logic [               XLEN-1:0] resp_data    [REQ_PORT_COUNT-1:0],
    output logic [REG_FILE_ADDR_WIDTH-1:0] resp_rd_addr [REQ_PORT_COUNT-1:0],
    output logic                           resp_valid   [REQ_PORT_COUNT-1:0],
    output logic                           lsu_busy     [REQ_PORT_COUNT-1:0],
    output logic                           lsu_stall    [REQ_PORT_COUNT-1:0],

    /* DCCM interface (port 0 is plug-and-play with the current SoC) */
    output logic [XLEN-1:0] dccm_raddr     [DCCM_PORT_COUNT-1:0],
    output logic            dccm_rvalid_in [DCCM_PORT_COUNT-1:0],
    input  logic [XLEN-1:0] dccm_rdata     [DCCM_PORT_COUNT-1:0],
    input  logic            dccm_rvalid_out[DCCM_PORT_COUNT-1:0],
    output logic [XLEN-1:0] dccm_waddr     [DCCM_PORT_COUNT-1:0],
    output logic            dccm_wen       [DCCM_PORT_COUNT-1:0],
    output logic [XLEN-1:0] dccm_wdata     [DCCM_PORT_COUNT-1:0],
    output logic [     3:0] dccm_wstrb     [DCCM_PORT_COUNT-1:0]
`ifdef TV_HAS_CORE_DEBUG
    ,
    output logic [XLEN-1:0] debug_instr_tag_out [REQ_PORT_COUNT-1:0],
    output logic [    31:0] debug_instr_out     [REQ_PORT_COUNT-1:0],
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

  lsu_mem_op_t load_push_data;
  logic        load_push_valid;
  logic        load_push_ready;
  lsu_mem_op_t load_pop_data;
  logic        load_pop_valid;
  logic        load_pop_ready;
  logic [$clog2(LOAD_QUEUE_DEPTH):0] load_occupancy;
  logic [ISSUE_WIDTH-1:0] load_lane_pending;

  lsu_mem_op_t store_push_data;
  logic        store_push_valid;
  logic        store_push_ready;
  lsu_mem_op_t store_pop_data;
  logic        store_pop_valid;
  logic        store_pop_ready;
  logic [$clog2(STORE_QUEUE_DEPTH):0] store_occupancy;
  logic [ISSUE_WIDTH-1:0] store_lane_pending;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_lookup_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_lookup_tag;
  logic cam_lookup_hit;
  logic [XLEN-1:0] cam_lookup_data;
  logic [3:0] cam_lookup_strb;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_lookup_b_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_lookup_b_tag;
  logic cam_lookup_b_hit;
  logic [XLEN-1:0] cam_lookup_b_data;
  logic [3:0] cam_lookup_b_strb;
  logic cam_update_valid;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_update_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_update_tag;
  logic [XLEN-1:0] cam_update_data;
  logic cam_update_b_valid;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_update_b_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_update_b_tag;
  logic [XLEN-1:0] cam_update_b_data;
  logic [3:0] cam_update_b_strb;
  logic cam_clear_valid;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_clear_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_clear_tag;
  logic cam_clear_b_valid;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_clear_b_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_clear_b_tag;
  logic cam_clear_c_valid;
  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] cam_clear_c_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_clear_c_tag;

  lsu_mem_op_t engine_op;
  logic        stream_valid;
  logic        cam_lookup_valid;
  logic [XLEN-1:0] cam_lookup_addr;
  logic        cam_lookup_b_valid;
  logic [XLEN-1:0] cam_lookup_b_addr;
  logic        ext_forward_valid;
  logic [XLEN-1:0] ext_forward_value;
  logic [3:0] ext_forward_strb;
  logic        ext_forward_b_valid;
  logic [XLEN-1:0] ext_forward_b_value;
  logic [3:0] ext_forward_b_strb;
  logic engine_stall;
  logic [LSU_LANE_ID_WIDTH-1:0] wb_lane_id;
  logic [XLEN-1:0] wb_data;
  logic [4:0] wb_rd_addr;
  logic wb_rd_wr_en;
  logic [LSU_LANE_ID_WIDTH-1:0] dc1_lane_id;
  logic dc1_lane_valid;
  logic [LSU_LANE_ID_WIDTH-1:0] dc2_lane_id;
  logic dc2_lane_valid;
  logic store_retire_valid;
  logic [XLEN-1:0] store_retire_addr;
  logic store_retire_line_clear_valid;
  logic [XLEN-1:0] store_retire_line_clear_addr;
  logic store_retire_line_clear_b_valid;
  logic [XLEN-1:0] store_retire_line_clear_b_addr;
  logic store_cam_fill_valid;
  logic [XLEN-1:0] store_cam_fill_addr;
  logic [XLEN-1:0] store_cam_fill_data;
  logic [3:0] store_cam_fill_strb;
  logic store_cam_fill_b_valid;
  logic [XLEN-1:0] store_cam_fill_b_addr;
  logic [XLEN-1:0] store_cam_fill_b_data;
  logic [3:0] store_cam_fill_b_strb;

  logic [XLEN-1:0] eng_dccm_raddr[1:0];
  logic eng_dccm_rvalid_in[1:0];
  logic [XLEN-1:0] eng_dccm_rdata[1:0];
  logic eng_dccm_rvalid_out[1:0];
  logic [XLEN-1:0] eng_dccm_waddr[1:0];
  logic eng_dccm_wen[1:0];
  logic [XLEN-1:0] eng_dccm_wdata[1:0];
  logic [3:0] eng_dccm_wstrb[1:0];

`ifdef TV_HAS_CORE_DEBUG
  logic [XLEN-1:0] eng_instr_tag_out;
  logic [31:0] eng_instr_out;
  logic eng_debug_store_dc2_valid;
  logic [XLEN-1:0] eng_debug_store_dc2_instr_tag;
  logic [31:0] eng_debug_store_dc2_instr;
  logic [XLEN-1:0] eng_debug_store_dc2_addr;
  logic [XLEN-1:0] eng_debug_store_dc2_wdata;
  logic eng_debug_store_dc3_valid;
  logic [XLEN-1:0] eng_debug_store_dc3_instr_tag;
  logic [31:0] eng_debug_store_dc3_instr;
  logic [XLEN-1:0] eng_debug_store_dc3_addr;
  logic [XLEN-1:0] eng_debug_store_dc3_wdata;
`endif

  lsu_load_queue #(
      .DEPTH(LOAD_QUEUE_DEPTH)
  ) load_q (
      .clk          (clk),
      .rstn         (rstn),
      .push_data    (load_push_data),
      .push_valid   (load_push_valid),
      .push_ready   (load_push_ready),
      .pop_data     (load_pop_data),
      .pop_valid    (load_pop_valid),
      .pop_ready    (load_pop_ready),
      .occupancy    (load_occupancy),
      .lane_pending (load_lane_pending)
  );

  lsu_store_queue #(
      .DEPTH(STORE_QUEUE_DEPTH)
  ) store_q (
      .clk              (clk),
      .rstn             (rstn),
      .push_data        (store_push_data),
      .push_valid       (store_push_valid),
      .push_ready       (store_push_ready),
      .pop_data         (store_pop_data),
      .pop_valid        (store_pop_valid),
      .pop_ready        (store_pop_ready),
      .occupancy        (store_occupancy),
      .lane_pending     (store_lane_pending),
      .lookup_index     (cam_lookup_index),
      .lookup_tag       (cam_lookup_tag),
      .lookup_hit       (cam_lookup_hit),
      .lookup_data      (cam_lookup_data),
      .lookup_strb      (cam_lookup_strb),
      .lookup_b_index   (cam_lookup_b_index),
      .lookup_b_tag     (cam_lookup_b_tag),
      .lookup_b_hit     (cam_lookup_b_hit),
      .lookup_b_data    (cam_lookup_b_data),
      .lookup_b_strb    (cam_lookup_b_strb),
      .cam_update_valid (cam_update_valid),
      .cam_update_index (cam_update_index),
      .cam_update_tag   (cam_update_tag),
      .cam_update_data  (cam_update_data),
      .cam_update_strb  (store_cam_fill_strb),
      .cam_update_b_valid(cam_update_b_valid),
      .cam_update_b_index(cam_update_b_index),
      .cam_update_b_tag (cam_update_b_tag),
      .cam_update_b_data(cam_update_b_data),
      .cam_update_b_strb(cam_update_b_strb),
      .cam_clear_valid  (cam_clear_valid),
      .cam_clear_index  (cam_clear_index),
      .cam_clear_tag    (cam_clear_tag),
      .cam_clear_b_valid(cam_clear_b_valid),
      .cam_clear_b_index(cam_clear_b_index),
      .cam_clear_b_tag  (cam_clear_b_tag),
      .cam_clear_c_valid(cam_clear_c_valid),
      .cam_clear_c_index(cam_clear_c_index),
      .cam_clear_c_tag  (cam_clear_c_tag)
  );

  lsu_engine engine (
      .clk              (clk),
      .rstn             (rstn),
      .engine_op        (engine_op),
      .ext_forward_valid(ext_forward_valid),
      .ext_forward_value(ext_forward_value),
      .ext_forward_strb (ext_forward_strb),
      .ext_forward_b_valid(ext_forward_b_valid),
      .ext_forward_b_value(ext_forward_b_value),
      .ext_forward_b_strb (ext_forward_b_strb),
      .cam_lookup_valid (cam_lookup_valid),
      .cam_lookup_addr  (cam_lookup_addr),
      .cam_lookup_b_valid(cam_lookup_b_valid),
      .cam_lookup_b_addr(cam_lookup_b_addr),
      .engine_stall     (engine_stall),
      .engine_busy      (),
      .wb_lane_id       (wb_lane_id),
      .wb_data          (wb_data),
      .wb_rd_addr       (wb_rd_addr),
      .wb_rd_wr_en      (wb_rd_wr_en),
      .dc1_lane_id      (dc1_lane_id),
      .dc1_lane_valid   (dc1_lane_valid),
      .dc2_lane_id      (dc2_lane_id),
      .dc2_lane_valid   (dc2_lane_valid),
      .store_retire_valid(store_retire_valid),
      .store_retire_addr (store_retire_addr),
      .store_retire_line_clear_valid(store_retire_line_clear_valid),
      .store_retire_line_clear_addr (store_retire_line_clear_addr),
      .store_retire_line_clear_b_valid(store_retire_line_clear_b_valid),
      .store_retire_line_clear_b_addr (store_retire_line_clear_b_addr),
      .store_cam_fill_valid(store_cam_fill_valid),
      .store_cam_fill_addr (store_cam_fill_addr),
      .store_cam_fill_data (store_cam_fill_data),
      .store_cam_fill_strb (store_cam_fill_strb),
      .store_cam_fill_b_valid(store_cam_fill_b_valid),
      .store_cam_fill_b_addr (store_cam_fill_b_addr),
      .store_cam_fill_b_data (store_cam_fill_b_data),
      .store_cam_fill_b_strb (store_cam_fill_b_strb),
      .dccm_raddr       (eng_dccm_raddr),
      .dccm_rvalid_in   (eng_dccm_rvalid_in),
      .dccm_rdata       (eng_dccm_rdata),
      .dccm_rvalid_out  (eng_dccm_rvalid_out),
      .dccm_waddr       (eng_dccm_waddr),
      .dccm_wen         (eng_dccm_wen),
      .dccm_wdata       (eng_dccm_wdata),
      .dccm_wstrb       (eng_dccm_wstrb)
`ifdef TV_HAS_CORE_DEBUG
      ,
      .instr_tag_out            (eng_instr_tag_out),
      .instr_out                (eng_instr_out),
      .debug_store_dc2_valid    (eng_debug_store_dc2_valid),
      .debug_store_dc2_instr_tag(eng_debug_store_dc2_instr_tag),
      .debug_store_dc2_instr    (eng_debug_store_dc2_instr),
      .debug_store_dc2_addr     (eng_debug_store_dc2_addr),
      .debug_store_dc2_wdata    (eng_debug_store_dc2_wdata),
      .debug_store_dc3_valid    (eng_debug_store_dc3_valid),
      .debug_store_dc3_instr_tag(eng_debug_store_dc3_instr_tag),
      .debug_store_dc3_instr    (eng_debug_store_dc3_instr),
      .debug_store_dc3_addr     (eng_debug_store_dc3_addr),
      .debug_store_dc3_wdata    (eng_debug_store_dc3_wdata)
`endif
  );

  /* Scalar path: stream live EXU operands into the engine each cycle, like legacy lsu.sv.
   * Load/store queues and lane_pending are retained for future superscalar dispatch. */
  assign load_push_data   = '0;
  assign store_push_data  = '0;
  assign load_push_valid  = 1'b0;
  assign store_push_valid = 1'b0;
  assign load_pop_ready   = 1'b0;
  assign store_pop_ready  = 1'b0;

  assign stream_valid = req_valid[0] & req_ctrl[0].legal;
  assign engine_op    = stream_valid ? lsu_pack_req(req_ctrl[0], '0) : '0;

  assign cam_lookup_index   = cam_lookup_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_lookup_tag     = cam_lookup_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];
  assign cam_lookup_b_index = cam_lookup_b_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_lookup_b_tag   = cam_lookup_b_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];
  assign ext_forward_valid  = cam_lookup_valid & cam_lookup_hit;
  assign ext_forward_value  = cam_lookup_data;
  assign ext_forward_strb   = cam_lookup_strb;
  assign ext_forward_b_valid = cam_lookup_b_valid & cam_lookup_b_hit;
  assign ext_forward_b_value = cam_lookup_b_data;
  assign ext_forward_b_strb  = cam_lookup_b_strb;

  assign req_ready = '{default: 1'b1};

  /* Update store CAM when the engine commits merged write data. */
  assign cam_update_valid = store_cam_fill_valid;
  assign cam_update_index = store_cam_fill_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_update_tag   = store_cam_fill_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];
  assign cam_update_data  = store_cam_fill_data;
  assign cam_update_b_valid = store_cam_fill_b_valid;
  assign cam_update_b_index = store_cam_fill_b_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_update_b_tag   = store_cam_fill_b_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];
  assign cam_update_b_data  = store_cam_fill_b_data;
  assign cam_update_b_strb  = store_cam_fill_b_strb;

  assign cam_clear_valid = store_retire_valid;
  assign cam_clear_index = store_retire_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_clear_tag   = store_retire_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];

  assign cam_clear_b_valid = store_retire_line_clear_valid;
  assign cam_clear_b_index = store_retire_line_clear_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_clear_b_tag   = store_retire_line_clear_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];

  assign cam_clear_c_valid = store_retire_line_clear_b_valid;
  assign cam_clear_c_index = store_retire_line_clear_b_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign cam_clear_c_tag   = store_retire_line_clear_b_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];

  /* Dual TDP ports: engine port i maps 1:1 onto DCCM port i. */
  generate
    for (genvar p = 0; p < DCCM_PORT_COUNT; p++) begin : g_dccm_ports
      assign dccm_raddr[p]       = eng_dccm_raddr[p];
      assign dccm_rvalid_in[p]   = eng_dccm_rvalid_in[p];
      assign eng_dccm_rdata[p]   = dccm_rdata[p];
      assign eng_dccm_rvalid_out[p] = dccm_rvalid_out[p];
      assign dccm_waddr[p]       = eng_dccm_waddr[p];
      assign dccm_wen[p]         = eng_dccm_wen[p];
      assign dccm_wdata[p]       = eng_dccm_wdata[p];
      assign dccm_wstrb[p]       = eng_dccm_wstrb[p];
    end
  endgenerate

  genvar lane;
  generate
    for (lane = 0; lane < REQ_PORT_COUNT; lane++) begin : g_lane_status
      logic lane_engine_busy;
      assign lane_engine_busy = (dc1_lane_valid & (dc1_lane_id == LSU_LANE_ID_WIDTH'(lane))) |
                                (dc2_lane_valid & (dc2_lane_id == LSU_LANE_ID_WIDTH'(lane)));

      assign lsu_busy[lane] = lane_engine_busy;
      assign lsu_stall[lane] = engine_stall;

      assign resp_valid[lane]   = wb_rd_wr_en & (wb_lane_id == LSU_LANE_ID_WIDTH'(lane));
      assign resp_data[lane]    = wb_data;
      assign resp_rd_addr[lane] = wb_rd_addr;

`ifdef TV_HAS_CORE_DEBUG
      assign debug_instr_tag_out[lane] = (resp_valid[lane]) ? eng_instr_tag_out : '0;
      assign debug_instr_out[lane]     = (resp_valid[lane]) ? eng_instr_out : '0;
`endif
    end
  endgenerate

`ifdef TV_HAS_CORE_DEBUG
  assign debug_store_dc2_valid     = eng_debug_store_dc2_valid;
  assign debug_store_dc2_instr_tag = eng_debug_store_dc2_instr_tag;
  assign debug_store_dc2_instr     = eng_debug_store_dc2_instr;
  assign debug_store_dc2_addr      = eng_debug_store_dc2_addr;
  assign debug_store_dc2_wdata     = eng_debug_store_dc2_wdata;
  assign debug_store_dc3_valid     = eng_debug_store_dc3_valid;
  assign debug_store_dc3_instr_tag = eng_debug_store_dc3_instr_tag;
  assign debug_store_dc3_instr     = eng_debug_store_dc3_instr;
  assign debug_store_dc3_addr      = eng_debug_store_dc3_addr;
  assign debug_store_dc3_wdata     = eng_debug_store_dc3_wdata;
`endif

endmodule
