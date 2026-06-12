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

module lsu_store_queue #(
    parameter int DEPTH = LSU_STORE_QUEUE_DEPTH
) (
    input  logic clk,
    input  logic rstn,

    input  lsu_mem_op_t push_data,
    input  logic        push_valid,
    output logic        push_ready,

    output lsu_mem_op_t pop_data,
    output logic        pop_valid,
    input  logic        pop_ready,

    output logic [$clog2(DEPTH):0] occupancy,
    output logic [ISSUE_WIDTH-1:0] lane_pending,

    /* Direct-mapped store CAM for load forwarding */
    input  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] lookup_index,
    input  logic [LSU_STORE_CAM_TAG_WIDTH-1:0]   lookup_tag,
    output logic                                  lookup_hit,
    output logic [XLEN-1:0]                       lookup_data,

    input  logic                                  cam_update_valid,
    input  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0]  cam_update_index,
    input  logic [LSU_STORE_CAM_TAG_WIDTH-1:0]    cam_update_tag,
    input  logic [XLEN-1:0]                       cam_update_data,

    input  logic                                  cam_clear_valid,
    input  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0]  cam_clear_index,
    input  logic [LSU_STORE_CAM_TAG_WIDTH-1:0]    cam_clear_tag,

    input  logic                                  cam_clear_b_valid,
    input  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0]  cam_clear_b_index,
    input  logic [LSU_STORE_CAM_TAG_WIDTH-1:0]    cam_clear_b_tag,

    input  logic                                  cam_clear_c_valid,
    input  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0]  cam_clear_c_index,
    input  logic [LSU_STORE_CAM_TAG_WIDTH-1:0]    cam_clear_c_tag
);

  localparam int PTR_WIDTH = $clog2(DEPTH);
  localparam int OCC_WIDTH = $clog2(DEPTH) + 1;

  lsu_mem_op_t entries[DEPTH];
  logic [PTR_WIDTH-1:0] wr_ptr;
  logic [PTR_WIDTH-1:0] rd_ptr;
  logic [OCC_WIDTH-1:0] count;

  logic [DEPTH-1:0] cam_valid;
  logic [DEPTH-1:0] cam_data_valid;
  logic [DEPTH-1:0][LSU_STORE_CAM_TAG_WIDTH-1:0] cam_tag;
  logic [DEPTH-1:0][XLEN-1:0] cam_data;

  logic [LSU_STORE_CAM_INDEX_WIDTH-1:0] push_index;
  logic [LSU_STORE_CAM_TAG_WIDTH-1:0] push_tag;

  logic [XLEN-1:0] push_addr;

  assign push_addr  = lsu_effective_addr(push_data);
  assign push_index = push_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign push_tag   = push_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];

  assign occupancy = count;
  assign push_ready = (count != OCC_WIDTH'(DEPTH));
  assign pop_valid  = (count != 0);
  assign pop_data   = entries[rd_ptr];

  assign lookup_hit  = cam_valid[lookup_index] & cam_data_valid[lookup_index] &
                       (cam_tag[lookup_index] == lookup_tag);
  assign lookup_data = cam_data[lookup_index];

  logic cam_clear_fire;
  logic cam_clear_b_fire;
  logic cam_clear_c_fire;
  logic cam_update_fire;

  assign cam_clear_fire = cam_clear_valid &
      ((cam_tag[cam_clear_index] == cam_clear_tag) |
       (cam_update_valid & (cam_update_index == cam_clear_index) &
        (cam_update_tag == cam_clear_tag)));
  assign cam_clear_b_fire = cam_clear_b_valid &
      ((cam_tag[cam_clear_b_index] == cam_clear_b_tag) |
       (cam_update_valid & (cam_update_index == cam_clear_b_index) &
        (cam_update_tag == cam_clear_b_tag)));
  assign cam_clear_c_fire = cam_clear_c_valid &
      ((cam_tag[cam_clear_c_index] == cam_clear_c_tag) |
       (cam_update_valid & (cam_update_index == cam_clear_c_index) &
        (cam_update_tag == cam_clear_c_tag)));
  assign cam_update_fire = cam_update_valid &
      ~((cam_clear_fire & (cam_update_index == cam_clear_index)) |
        (cam_clear_b_fire & (cam_update_index == cam_clear_b_index)) |
        (cam_clear_c_fire & (cam_update_index == cam_clear_c_index)));

  always_comb begin
    lane_pending = '0;
    for (int e = 0; e < DEPTH; e++) begin
      if (e < int'(count)) begin
        automatic int slot = (int'(rd_ptr) + e) % DEPTH;
        automatic int lane = int'(entries[slot].lane_id);
        lane_pending[lane] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr_ptr    <= '0;
      rd_ptr    <= '0;
      count     <= '0;
      cam_valid      <= '0;
      cam_data_valid <= '0;
    end else begin
      if (push_valid & push_ready) begin
        entries[wr_ptr] <= push_data;
        wr_ptr <= (wr_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : wr_ptr + PTR_WIDTH'(1);
        cam_valid[push_index]      <= 1'b1;
        cam_data_valid[push_index] <= 1'b0;
        cam_tag[push_index]        <= push_tag;
      end

      if (pop_valid & pop_ready) begin
        rd_ptr <= (rd_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : rd_ptr + PTR_WIDTH'(1);
      end

      unique case ({push_valid & push_ready, pop_valid & pop_ready})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase

      /* Retire clears win over fill: completed stores must not leave stale CAM entries. */
      if (cam_clear_fire) begin
        cam_valid[cam_clear_index]      <= 1'b0;
        cam_data_valid[cam_clear_index] <= 1'b0;
      end

      if (cam_clear_b_fire) begin
        cam_valid[cam_clear_b_index]      <= 1'b0;
        cam_data_valid[cam_clear_b_index] <= 1'b0;
      end

      if (cam_clear_c_fire) begin
        cam_valid[cam_clear_c_index]      <= 1'b0;
        cam_data_valid[cam_clear_c_index] <= 1'b0;
      end

      if (cam_update_fire) begin
        cam_valid[cam_update_index]      <= 1'b1;
        cam_data_valid[cam_update_index] <= 1'b1;
        cam_tag[cam_update_index]        <= cam_update_tag;
        cam_data[cam_update_index]       <= cam_update_data;
      end
    end
  end

endmodule
