`ifndef ZVE32X_DECODE_OUT_T_SVH
`define ZVE32X_DECODE_OUT_T_SVH
typedef struct packed {
	logic vec;
	logic vset;
	logic vcsr;
	logic vload;
	logic vstore;
	logic valu;
	logic rs1;
	logic rs2;
	logic rd;
	logic legal;
} zve32x_decode_out_t;
`endif
