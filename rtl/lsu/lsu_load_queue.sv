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

module lsu_load_queue #(
    parameter int DEPTH = LSU_LOAD_QUEUE_DEPTH
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
    output logic [ISSUE_WIDTH-1:0] lane_pending
);

  localparam int PTR_WIDTH = $clog2(DEPTH);
  localparam int OCC_WIDTH = $clog2(DEPTH) + 1;

  lsu_mem_op_t entries[DEPTH];
  logic [PTR_WIDTH-1:0] wr_ptr;
  logic [PTR_WIDTH-1:0] rd_ptr;
  logic [OCC_WIDTH-1:0] count;

  logic push_fire;
  logic pop_fire;
  logic [PTR_WIDTH-1:0] wr_ptr_next;
  logic [PTR_WIDTH-1:0] rd_ptr_next;
  logic [OCC_WIDTH-1:0] count_next;

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
