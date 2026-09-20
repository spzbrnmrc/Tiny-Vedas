///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// One e32 valu lane. Add/sub is SVLib kogge_stone adder (same cell as
// scalar mul CPA). Logic/compare mux matches rtl/scalar/exu/alu.sv.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

module valu_lane (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [ 5:0] funct6,
    output logic [31:0] result,
    output logic        cmp_bit
);

  logic is_sub;
  logic is_rsub;
  logic is_minmax;
  logic is_mskc;

  assign is_sub    = (funct6 == 6'b000010);
  assign is_rsub   = (funct6 == 6'b000011);
  assign is_minmax = (funct6 == 6'b000100) || (funct6 == 6'b000101) ||
                     (funct6 == 6'b000110) || (funct6 == 6'b000111);
  assign is_mskc   = (funct6[5:3] == 3'b011);

  logic [31:0] add_a;
  logic [31:0] add_b;
  logic        cin;
  logic [31:0] sum;
  logic        cout;

  always_comb begin
    add_a = a;
    add_b = b;
    cin   = 1'b0;
    if (is_sub || is_minmax || is_mskc) begin
      add_b = ~b;
      cin   = 1'b1;
    end else if (is_rsub) begin
      add_a = b;
      add_b = ~a;
      cin   = 1'b1;
    end
  end

  adder #(
      .WIDTH    (32),
      .ALGORITHM(2)
  ) u_add (
      .in0 (add_a),
      .in1 (add_b),
      .cin (cin),
      .sum (sum),
      .cout(cout)
  );

  logic ov;
  logic neg;
  logic eq;
  logic lt_s;
  logic lt_u;

  assign neg  = sum[31];
  assign ov   = (~add_a[31] & ~add_b[31] & sum[31]) | (add_a[31] & add_b[31] & ~sum[31]);
  assign eq   = (sum == 32'd0);
  assign lt_s = neg ^ ov;
  assign lt_u = ~cout;

  logic [31:0] lout;
  logic [ 4:0] shamt;
  logic [31:0] sll;
  logic [31:0] srl;
  logic [31:0] sra;

  assign lout  = ({32{funct6 == 6'b001001}} & (a & b)) |
                 ({32{funct6 == 6'b001010}} & (a | b)) |
                 ({32{funct6 == 6'b001011}} & (a ^ b));
  assign shamt = b[4:0];
  assign sll   = a << shamt;
  assign srl   = a >> shamt;
  assign sra   = $unsigned($signed(a) >>> shamt);

  always_comb begin
    cmp_bit = 1'b0;
    unique case (funct6)
      6'b011000: cmp_bit = eq;
      6'b011001: cmp_bit = ~eq;
      6'b011010: cmp_bit = lt_u;
      6'b011011: cmp_bit = lt_s;
      6'b011100: cmp_bit = lt_u || eq;
      6'b011101: cmp_bit = lt_s || eq;
      6'b011110: cmp_bit = ~lt_u && ~eq;
      6'b011111: cmp_bit = ~lt_s && ~eq;
      default:   cmp_bit = 1'b0;
    endcase
  end

  always_comb begin
    unique case (funct6)
      6'b000000: result = sum;
      6'b000010: result = sum;
      6'b000011: result = sum;
      6'b000100: result = (lt_u || eq) ? a : b;
      6'b000101: result = (lt_s || eq) ? a : b;
      6'b000110: result = (!lt_u) ? a : b;
      6'b000111: result = (!lt_s) ? a : b;
      6'b001001: result = lout;
      6'b001010: result = lout;
      6'b001011: result = lout;
      6'b010111: result = b;
      6'b100101: result = sll;
      6'b101000: result = srl;
      6'b101001: result = sra;
      default:   result = 32'd0;
    endcase
  end

endmodule
