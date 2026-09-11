`ifndef AXI4_SVH
`define AXI4_SVH

/* AXI4 parameters for Tiny-Vedas tightly-coupled memories. */
localparam int AXI_ID_WIDTH   = 4;
localparam int AXI_ADDR_WIDTH = 32;
localparam int AXI_DATA_WIDTH = 32;
localparam int AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8;
localparam int AXI_LEN_WIDTH  = 8;
localparam int AXI_SIZE_WIDTH = 3;
localparam int AXI_BURST_WIDTH = 2;
localparam int AXI_RESP_WIDTH = 2;

localparam logic [AXI_SIZE_WIDTH-1:0] AXI_SIZE_4B = 3'b010;
localparam logic [AXI_BURST_WIDTH-1:0] AXI_BURST_INCR = 2'b01;
localparam logic [AXI_RESP_WIDTH-1:0] AXI_RESP_OKAY = 2'b00;

`endif
