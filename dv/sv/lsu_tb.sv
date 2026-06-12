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

module lsu_tb;

  logic clk = 0;
  logic rstn = 0;

  idu1_out_t lsu_ctrl, lsu_ctrl_d;
  lsu_mem_op_t engine_op;

  logic engine_stall;
  logic [XLEN-1:0] wb_data;
  logic [4:0] wb_rd_addr;
  logic wb_rd_wr_en;

  logic [XLEN-1:0] dccm_raddr;
  logic            dccm_rvalid_in;
  logic [XLEN-1:0] dccm_rdata;
  logic            dccm_rvalid_out;
  logic [XLEN-1:0] dccm_waddr;
  logic            dccm_wen;
  logic [XLEN-1:0] dccm_wdata;

  assign engine_op = lsu_pack_req(lsu_ctrl, '0);

  always #5 clk = ~clk;

  lsu_engine DUT (
      .clk              (clk),
      .rstn             (rstn),
      .engine_op        (engine_op),
      .ext_forward_valid(1'b0),
      .ext_forward_value('0),
      .cam_lookup_valid (),
      .cam_lookup_addr  (),
      .engine_stall     (engine_stall),
      .engine_busy      (),
      .wb_lane_id       (),
      .wb_data          (wb_data),
      .wb_rd_addr       (wb_rd_addr),
      .wb_rd_wr_en      (wb_rd_wr_en),
      .dc1_lane_id      (),
      .dc1_lane_valid   (),
      .dc2_lane_id      (),
      .dc2_lane_valid   (),
      .store_retire_valid(),
      .store_retire_addr (),
      .store_cam_fill_valid(),
      .store_cam_fill_addr(),
      .store_cam_fill_data(),
      .dccm_raddr       (dccm_raddr),
      .dccm_rvalid_in   (dccm_rvalid_in),
      .dccm_rdata       (dccm_rdata),
      .dccm_rvalid_out  (dccm_rvalid_out),
      .dccm_waddr       (dccm_waddr),
      .dccm_wen         (dccm_wen),
      .dccm_wdata       (dccm_wdata)
  );

  always_ff @(posedge clk) begin
    lsu_ctrl <= lsu_ctrl_d;
  end

  initial begin
    $timeformat(-9, 3, " ns", 10);
    lsu_ctrl_d = 0;
    for (int i = 0; i < 10; i++) begin
      @(negedge clk);
    end
    rstn = 1;
    for (int i = 0; i < 10; i++) begin
      @(negedge clk);
    end
    lsu_ctrl_d.rd_addr = 5;
    lsu_ctrl_d.by = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h00000FF0;
    @(negedge clk);
    lsu_ctrl_d.rd_addr = 3;
    lsu_ctrl_d.by = 0;
    lsu_ctrl_d.half = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h00001FF0;
    @(negedge clk);
    lsu_ctrl_d.rd_addr = 7;
    lsu_ctrl_d.half = 0;
    lsu_ctrl_d.word = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h00002FF0;
    @(negedge clk);
    lsu_ctrl_d = 0;
    @(negedge clk);
    lsu_ctrl_d.rd_addr = 5;
    lsu_ctrl_d.by = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h00003FF1;
    @(negedge clk);
    lsu_ctrl_d = 0;
    lsu_ctrl_d.rd_addr = 3;
    lsu_ctrl_d.half = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h00004F2;
    @(negedge clk);
    lsu_ctrl_d = 0;
    lsu_ctrl_d.rd_addr = 10;
    lsu_ctrl_d.half = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h00005F3;
    @(negedge clk);
    lsu_ctrl_d = 0;
    @(negedge clk);
    lsu_ctrl_d.rd_addr = 12;
    lsu_ctrl_d.half = 1;
    lsu_ctrl_d.load = 1;
    lsu_ctrl_d.legal = 1;
    lsu_ctrl_d.rs1_data = 32'h000056F3;
    @(negedge clk);
    lsu_ctrl_d = 0;
    for (int i = 0; i < 100; i++) begin
      @(negedge clk);
    end
    $finish;
  end

  always_ff @(posedge clk) begin
    dccm_rdata <= 0;
    dccm_rvalid_out <= 0;
    if (dccm_rvalid_in) begin
      dccm_rdata <= $urandom;
      dccm_rvalid_out <= 1;
    end
  end

endmodule
