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

  logic push_fire;
  logic pop_fire;
  logic [PTR_WIDTH-1:0] wr_ptr_next;
  logic [PTR_WIDTH-1:0] rd_ptr_next;
  logic [OCC_WIDTH-1:0] count_next;

  logic cam_clear_fire;
  logic cam_clear_b_fire;
  logic cam_clear_c_fire;
  logic cam_update_fire;

  assign push_addr  = lsu_effective_addr(push_data);
  assign push_index = push_addr[LSU_STORE_CAM_INDEX_WIDTH-1:0];
  assign push_tag   = push_addr[XLEN-1:LSU_STORE_CAM_INDEX_WIDTH];

  assign push_fire = push_valid & push_ready;
  assign pop_fire  = pop_valid & pop_ready;

  assign wr_ptr_next = (wr_ptr == PTR_WIDTH'(DEPTH - 1)) ? PTR_WIDTH'(0) : (wr_ptr + PTR_WIDTH'(1));
  assign rd_ptr_next = (rd_ptr == PTR_WIDTH'(DEPTH - 1)) ? PTR_WIDTH'(0) : (rd_ptr + PTR_WIDTH'(1));

  always_comb begin
    count_next = count;
    unique case ({push_fire, pop_fire})
      2'b10: count_next = count + OCC_WIDTH'(1);
      2'b01: count_next = count - OCC_WIDTH'(1);
      default: ;
    endcase
  end

  assign occupancy = count;
  assign push_ready = (count != OCC_WIDTH'(DEPTH));
  assign pop_valid  = (count != 0);
  assign pop_data   = entries[rd_ptr];

  assign lookup_hit  = cam_valid[lookup_index] & cam_data_valid[lookup_index] &
                       (cam_tag[lookup_index] == lookup_tag);
  assign lookup_data = cam_data[lookup_index];

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

  register_en_sync_rstn #(
      .WIDTH(PTR_WIDTH)
  ) wr_ptr_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (push_fire),
      .din (wr_ptr_next),
      .dout(wr_ptr)
  );

  register_en_sync_rstn #(
      .WIDTH(PTR_WIDTH)
  ) rd_ptr_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (pop_fire),
      .din (rd_ptr_next),
      .dout(rd_ptr)
  );

  register_en_sync_rstn #(
      .WIDTH(OCC_WIDTH)
  ) count_ff (
      .clk (clk),
      .rstn(rstn),
      .en  (push_fire | pop_fire),
      .din (count_next),
      .dout(count)
  );

  genvar entry;
  generate
    for (entry = 0; entry < DEPTH; entry++) begin : g_entries
      register_en_sync_rstn #(
          .WIDTH($bits(lsu_mem_op_t))
      ) entry_ff (
          .clk (clk),
          .rstn(rstn),
          .en  (push_fire & (wr_ptr == PTR_WIDTH'(entry))),
          .din (push_data),
          .dout(entries[entry])
      );
    end
  endgenerate

  genvar cam_slot;
  generate
    for (cam_slot = 0; cam_slot < DEPTH; cam_slot++) begin : g_cam
      logic cam_valid_en;
      logic cam_valid_din;
      logic cam_data_valid_en;
      logic cam_data_valid_din;
      logic cam_tag_en;
      logic [LSU_STORE_CAM_TAG_WIDTH-1:0] cam_tag_din;
      logic cam_data_en;
      logic [XLEN-1:0] cam_data_din;

      always_comb begin
        cam_valid_en       = 1'b0;
        cam_valid_din      = cam_valid[cam_slot];
        cam_data_valid_en  = 1'b0;
        cam_data_valid_din = cam_data_valid[cam_slot];
        cam_tag_en         = 1'b0;
        cam_tag_din        = cam_tag[cam_slot];
        cam_data_en        = 1'b0;
        cam_data_din       = cam_data[cam_slot];

        if (cam_update_fire && (cam_update_index == LSU_STORE_CAM_INDEX_WIDTH'(cam_slot))) begin
          cam_valid_en       = 1'b1;
          cam_valid_din      = 1'b1;
          cam_data_valid_en  = 1'b1;
          cam_data_valid_din = 1'b1;
          cam_tag_en         = 1'b1;
          cam_tag_din        = cam_update_tag;
          cam_data_en        = 1'b1;
          cam_data_din       = cam_update_data;
        end else if ((cam_clear_fire && (cam_clear_index == LSU_STORE_CAM_INDEX_WIDTH'(cam_slot))) ||
                     (cam_clear_b_fire && (cam_clear_b_index == LSU_STORE_CAM_INDEX_WIDTH'(cam_slot))) ||
                     (cam_clear_c_fire && (cam_clear_c_index == LSU_STORE_CAM_INDEX_WIDTH'(cam_slot)))) begin
          cam_valid_en       = 1'b1;
          cam_valid_din      = 1'b0;
          cam_data_valid_en  = 1'b1;
          cam_data_valid_din = 1'b0;
        end else if (push_fire && (push_index == LSU_STORE_CAM_INDEX_WIDTH'(cam_slot))) begin
          cam_valid_en       = 1'b1;
          cam_valid_din      = 1'b1;
          cam_data_valid_en  = 1'b1;
          cam_data_valid_din = 1'b0;
          cam_tag_en         = 1'b1;
          cam_tag_din        = push_tag;
        end
      end

      register_en_sync_rstn #(
          .WIDTH(1)
      ) cam_valid_ff (
          .clk (clk),
          .rstn(rstn),
          .en  (cam_valid_en),
          .din (cam_valid_din),
          .dout(cam_valid[cam_slot])
      );

      register_en_sync_rstn #(
          .WIDTH(1)
      ) cam_data_valid_ff (
          .clk (clk),
          .rstn(rstn),
          .en  (cam_data_valid_en),
          .din (cam_data_valid_din),
          .dout(cam_data_valid[cam_slot])
      );

      register_en_sync_rstn #(
          .WIDTH(LSU_STORE_CAM_TAG_WIDTH)
      ) cam_tag_ff (
          .clk (clk),
          .rstn(rstn),
          .en  (cam_tag_en),
          .din (cam_tag_din),
          .dout(cam_tag[cam_slot])
      );

      register_en_sync_rstn #(
          .WIDTH(XLEN)
      ) cam_data_ff (
          .clk (clk),
          .rstn(rstn),
          .en  (cam_data_en),
          .din (cam_data_din),
          .dout(cam_data[cam_slot])
      );
    end
  endgenerate

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

endmodule
