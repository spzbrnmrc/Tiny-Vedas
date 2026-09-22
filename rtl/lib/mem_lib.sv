///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////

/* ************** Memory Library ************** */

/**** True dual-port sync RAM (Xilinx UG901 rams_tdp_rf_rf byte-write) ********
 * Portable — no bus/AXI inside. Per-byte write strobes on each port.
 * Read latency: 1 cycle when en*=1. Data outs hold when en*=0 (BRAM).
 */
module sync_tdp_mem #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = "",
    parameter string RAM_STYLE = "block"
) (
    input  logic                         clka,
    input  logic                         clkb,
    input  logic                         ena,
    input  logic                         enb,
    input  logic [            WIDTH/8-1:0] wea,
    input  logic [            WIDTH/8-1:0] web,
    input  logic [      $clog2(DEPTH)-1:0] addra,
    input  logic [      $clog2(DEPTH)-1:0] addrb,
    input  logic [              WIDTH-1:0] dia,
    input  logic [              WIDTH-1:0] dib,
    output logic [              WIDTH-1:0] doa,
    output logic [              WIDTH-1:0] dob
);

  localparam int NBYTES = WIDTH / 8;

  /* ram_style must be a string literal — Vivado rejects a parameter here. */
  generate
    if (RAM_STYLE == "ultra") begin : g_ram
      (* ram_style = "ultra" *) logic [WIDTH-1:0] ram[DEPTH];
      initial begin
        if (INIT_FILE != "") begin
          $readmemh(INIT_FILE, ram);
        end
      end
      always_ff @(posedge clka) begin
        if (ena) begin
          for (int i = 0; i < NBYTES; i++) begin
            if (wea[i]) ram[addra][8*i+:8] <= dia[8*i+:8];
          end
          doa <= ram[addra];
        end
      end
      always_ff @(posedge clkb) begin
        if (enb) begin
          for (int i = 0; i < NBYTES; i++) begin
            if (web[i]) ram[addrb][8*i+:8] <= dib[8*i+:8];
          end
          dob <= ram[addrb];
        end
      end
    end else begin : g_ram
      (* ram_style = "block" *) logic [WIDTH-1:0] ram[DEPTH];
      initial begin
        for (int i = 0; i < DEPTH; i++) ram[i] = '0;
        if (INIT_FILE != "") begin
          $readmemh(INIT_FILE, ram);
        end
      end
      always_ff @(posedge clka) begin
        if (ena) begin
          for (int i = 0; i < NBYTES; i++) begin
            if (wea[i]) ram[addra][8*i+:8] <= dia[8*i+:8];
          end
          doa <= ram[addra];
        end
      end
      always_ff @(posedge clkb) begin
        if (enb) begin
          for (int i = 0; i < NBYTES; i++) begin
            if (web[i]) ram[addrb][8*i+:8] <= dib[8*i+:8];
          end
          dob <= ram[addrb];
        end
      end
    end
  endgenerate

endmodule

/**** Instruction Closely Coupled Memory ************** */

/* Port A = fetch (sync read), port B = host write with byte strobes. */
module iccm #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic rstn,

    input  logic [($clog2(DEPTH*WIDTH/8))-1:0] raddr,
    input  logic                               rvalid_in,
    input  logic [    INSTR_MEM_TAG_WIDTH-1:0] rtag_in,
    output logic [                  WIDTH-1:0] rdata,
    output logic                               rvalid_out,
    output logic [    INSTR_MEM_TAG_WIDTH-1:0] rtag_out,

    input logic                     wen,
    input logic [$clog2(DEPTH)-1:0] waddr,
    input logic [        WIDTH-1:0] wdata,
    input logic [      WIDTH/8-1:0] wstrb
);

  localparam int AW = $clog2(DEPTH);
  localparam int BYTE_AW = $clog2(DEPTH * WIDTH / 8);

  logic [AW-1:0] word_idx;
  assign word_idx = raddr[BYTE_AW-1:$clog2(WIDTH/8)];

  logic [WIDTH-1:0] doa, dob_unused;

  sync_tdp_mem #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH),
      .INIT_FILE(INIT_FILE)
  ) u_mem (
      .clka (clk),
      .clkb (clk),
      .ena  (rvalid_in),
      .enb  (wen),
      .wea  ('0),
      .web  ({(WIDTH/8){wen}} & wstrb),
      .addra(word_idx),
      .addrb(waddr),
      .dia  ('0),
      .dib  (wdata),
      .doa  (doa),
      .dob  (dob_unused)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rvalid_out <= 1'b0;
      rtag_out   <= '0;
    end else begin
      rvalid_out <= rvalid_in;
      rtag_out   <= rtag_in;
    end
  end

  /* BRAM holds when !ena — IFU must ignore when !rvalid_out. */
  assign rdata = doa;

endmodule

/**** Data Closely Coupled Memory ************** */

/* Port A = sync read, port B = byte-strobe write. Same sync_tdp_mem as FPGA. */
module dccm #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic rstn,

    input  logic [$clog2(DEPTH)-1:0] raddr,
    input  logic                     rvalid_in,
    output logic [        WIDTH-1:0] rdata,
    output logic                     rvalid_out,

    input logic [$clog2(DEPTH)-1:0] waddr,
    input logic                     wen,
    input logic [        WIDTH-1:0] wdata,
    input logic [      WIDTH/8-1:0] wstrb
);

  logic [WIDTH-1:0] doa, dob_unused;

  sync_tdp_mem #(
      .DEPTH(DEPTH),
      .WIDTH(WIDTH),
      .INIT_FILE(INIT_FILE)
  ) u_mem (
      .clka (clk),
      .clkb (clk),
      .ena  (rvalid_in),
      .enb  (wen),
      .wea  ('0),
      .web  ({(WIDTH/8){wen}} & wstrb),
      .addra(raddr),
      .addrb(waddr),
      .dia  ('0),
      .dib  (wdata),
      .doa  (doa),
      .dob  (dob_unused)
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      rvalid_out <= 1'b0;
    end else begin
      rvalid_out <= rvalid_in;
    end
  end

  /* Hold doa when idle — LSU may sample past the valid pulse (UG901). */
  assign rdata = doa;

endmodule
