///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//     Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Dual-port AXI4 (LEN=0) DRAM stub for Alveo U280.
// 64-bit XPM UltraRAM (native aspect). 8-bit TDP XPM falls back to BRAM.
// URAM TDP: WRITE_MODE no_change, READ_LATENCY 3. Byte/word writes RMW.

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef AXI4_SVH
`include "axi4.svh"
`endif

module axi4_dram #(
    parameter int DEPTH = 4194304,
    parameter logic [31:0] BASE = 32'h40000000,
    parameter string INIT_FILE = ""
) (
    input logic clk,
    input logic rstn,

    input  logic [   AXI_ID_WIDTH-1:0] s0_axi_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s0_axi_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s0_axi_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s0_axi_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s0_axi_arburst,
    input  logic                        s0_axi_arvalid,
    output logic                        s0_axi_arready,
    output logic [   AXI_ID_WIDTH-1:0] s0_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]  s0_axi_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] s0_axi_rresp,
    output logic                        s0_axi_rlast,
    output logic                        s0_axi_rvalid,
    input  logic                        s0_axi_rready,

    input  logic [   AXI_ID_WIDTH-1:0] s0_axi_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s0_axi_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s0_axi_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s0_axi_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s0_axi_awburst,
    input  logic                        s0_axi_awvalid,
    output logic                        s0_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  s0_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  s0_axi_wstrb,
    input  logic                        s0_axi_wlast,
    input  logic                        s0_axi_wvalid,
    output logic                        s0_axi_wready,
    output logic [   AXI_ID_WIDTH-1:0] s0_axi_bid,
    output logic [ AXI_RESP_WIDTH-1:0] s0_axi_bresp,
    output logic                        s0_axi_bvalid,
    input  logic                        s0_axi_bready,

    input  logic [   AXI_ID_WIDTH-1:0] s1_axi_arid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s1_axi_araddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s1_axi_arlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s1_axi_arsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s1_axi_arburst,
    input  logic                        s1_axi_arvalid,
    output logic                        s1_axi_arready,
    output logic [   AXI_ID_WIDTH-1:0] s1_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]  s1_axi_rdata,
    output logic [ AXI_RESP_WIDTH-1:0] s1_axi_rresp,
    output logic                        s1_axi_rlast,
    output logic                        s1_axi_rvalid,
    input  logic                        s1_axi_rready,

    input  logic [   AXI_ID_WIDTH-1:0] s1_axi_awid,
    input  logic [ AXI_ADDR_WIDTH-1:0] s1_axi_awaddr,
    input  logic [   AXI_LEN_WIDTH-1:0] s1_axi_awlen,
    input  logic [  AXI_SIZE_WIDTH-1:0] s1_axi_awsize,
    input  logic [ AXI_BURST_WIDTH-1:0] s1_axi_awburst,
    input  logic                        s1_axi_awvalid,
    output logic                        s1_axi_awready,
    input  logic [AXI_DATA_WIDTH-1:0]  s1_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]  s1_axi_wstrb,
    input  logic                        s1_axi_wlast,
    input  logic                        s1_axi_wvalid,
    output logic                        s1_axi_wready,
    output logic [   AXI_ID_WIDTH-1:0] s1_axi_bid,
    output logic [ AXI_RESP_WIDTH-1:0] s1_axi_bresp,
    output logic                        s1_axi_bvalid,
    input  logic                        s1_axi_bready,

    input  logic        host_en,
    input  logic        host_wr,
    input  logic [31:0] host_addr,
    input  logic [31:0] host_din,
    input  logic [ 3:0] host_wstrb,
    output logic [31:0] host_dout,
    output logic        host_rvalid,
    output logic        host_wdone
);

  localparam int WORD_AW = $clog2(DEPTH);
  localparam int UAW = WORD_AW - 1;
  localparam int UDEPTH = DEPTH / 2;

  function automatic logic [WORD_AW-1:0] word_idx(input logic [31:0] addr);
    logic [31:0] off;
    off = addr - BASE;
    return off[WORD_AW+1:2];
  endfunction

  function automatic logic [63:0] merge64(
      input logic [63:0] oldv,
      input logic [31:0] wdata,
      input logic [ 3:0] strb,
      input logic        hi
  );
    begin
      merge64 = oldv;
      if (!hi) begin
        if (strb[0]) merge64[7:0] = wdata[7:0];
        if (strb[1]) merge64[15:8] = wdata[15:8];
        if (strb[2]) merge64[23:16] = wdata[23:16];
        if (strb[3]) merge64[31:24] = wdata[31:24];
      end else begin
        if (strb[0]) merge64[39:32] = wdata[7:0];
        if (strb[1]) merge64[47:40] = wdata[15:8];
        if (strb[2]) merge64[55:48] = wdata[23:16];
        if (strb[3]) merge64[63:56] = wdata[31:24];
      end
    end
  endfunction

  logic        ena, enb, wea, web;
  logic [UAW-1:0] addra, addrb;
  logic [63:0]    dia, dib, doa, dob;

  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_R1    = 3'd1,
    ST_R2    = 3'd2,
    ST_R3    = 3'd3,
    ST_WR    = 3'd4,
    ST_B     = 3'd5
  } st_e;

  st_e st0, st1;
  logic [WORD_AW-1:0] widx0, widx1;
  logic [31:0] wdata0, wdata1;
  logic [3:0]  wstrb0, wstrb1;
  logic [63:0] old0, old1;
  logic [AXI_ID_WIDTH-1:0] bid0, bid1, rid0, rid1;
  logic [2:0] rd0_v, rd1_v;
  logic [2:0] rd0_hi, rd1_hi;
  logic [AXI_ID_WIDTH-1:0] rid0_s[3];
  logic [AXI_ID_WIDTH-1:0] rid1_s[3];

  logic s0_busy, s1_busy, wr1_host;
  logic [2:0] host_rd_v, host_rd_hi;
  logic [WORD_AW-1:0] s0_ar_widx, s0_aw_widx, s1_ar_widx, s1_aw_widx;
  logic [UAW-1:0] rd0_uaddr, rd1_uaddr;
  assign s0_ar_widx = word_idx(s0_axi_araddr);
  assign s0_aw_widx = word_idx(s0_axi_awaddr);
  assign s1_ar_widx = word_idx(s1_axi_araddr);
  assign s1_aw_widx = word_idx(s1_axi_awaddr);
  assign s0_busy = ((st0 != ST_IDLE) && (st0 != ST_B)) || (rd0_v != 3'b0);
  assign s1_busy = host_en || ((st1 != ST_IDLE) && (st1 != ST_B)) || (rd1_v != 3'b0)
                   || (host_rd_v != 3'b0);

  assign s0_axi_arready = !s0_busy && (st0 == ST_IDLE);
  assign s0_axi_awready = !s0_busy && (st0 == ST_IDLE) && !s0_axi_arvalid && s0_axi_wvalid;
  assign s0_axi_wready  = !s0_busy && (st0 == ST_IDLE) && !s0_axi_arvalid && s0_axi_awvalid;
  assign s1_axi_arready = !s1_busy && (st1 == ST_IDLE);
  assign s1_axi_awready = !s1_busy && (st1 == ST_IDLE) && !s1_axi_arvalid && !host_en
                          && s1_axi_wvalid;
  assign s1_axi_wready  = !s1_busy && (st1 == ST_IDLE) && !s1_axi_arvalid && !host_en
                          && s1_axi_awvalid;

  logic s0_ar_fire, s0_wr_fire, s1_ar_fire, s1_wr_fire;
  assign s0_ar_fire = s0_axi_arvalid & s0_axi_arready;
  assign s0_wr_fire = s0_axi_awvalid & s0_axi_awready & s0_axi_wvalid & s0_axi_wready;
  assign s1_ar_fire = s1_axi_arvalid & s1_axi_arready;
  assign s1_wr_fire = s1_axi_awvalid & s1_axi_awready & s1_axi_wvalid & s1_axi_wready;

  always_comb begin
    ena   = 1'b0;
    wea   = 1'b0;
    addra = '0;
    dia   = '0;
    if (s0_ar_fire) begin
      ena   = 1'b1;
      addra = s0_ar_widx[WORD_AW-1:1];
    end else if (rd0_v[1:0] != 2'b0) begin
      ena   = 1'b1;
      addra = rd0_uaddr;
    end else if (st0 == ST_IDLE && s0_wr_fire) begin
      ena   = 1'b1;
      addra = s0_aw_widx[WORD_AW-1:1];
    end else if (st0 == ST_R1 || st0 == ST_R2 || st0 == ST_R3) begin
      ena   = 1'b1;
      addra = widx0[WORD_AW-1:1];
    end else if (st0 == ST_WR) begin
      ena   = 1'b1;
      wea   = 1'b1;
      addra = widx0[WORD_AW-1:1];
      dia   = merge64(old0, wdata0, wstrb0, widx0[0]);
    end

    enb   = 1'b0;
    web   = 1'b0;
    addrb = '0;
    dib   = '0;
    if (host_en && !host_wr) begin
      enb   = 1'b1;
      addrb = host_addr[WORD_AW+1:3];
    end else if (host_en && host_wr && (st1 == ST_IDLE)) begin
      enb   = 1'b1;
      addrb = host_addr[WORD_AW+1:3];
    end else if (st1 == ST_IDLE && s1_ar_fire) begin
      enb   = 1'b1;
      addrb = s1_ar_widx[WORD_AW-1:1];
    end else if (rd1_v[1:0] != 2'b0) begin
      enb   = 1'b1;
      addrb = rd1_uaddr;
    end else if (st1 == ST_IDLE && s1_wr_fire) begin
      enb   = 1'b1;
      addrb = s1_aw_widx[WORD_AW-1:1];
    end else if (st1 == ST_R1 || st1 == ST_R2 || st1 == ST_R3) begin
      enb   = 1'b1;
      addrb = widx1[WORD_AW-1:1];
    end else if (st1 == ST_WR) begin
      enb   = 1'b1;
      web   = 1'b1;
      addrb = widx1[WORD_AW-1:1];
      dib   = merge64(old1, wdata1, wstrb1, widx1[0]);
    end
  end

  xpm_memory_tdpram #(
      .ADDR_WIDTH_A(UAW),
      .ADDR_WIDTH_B(UAW),
      .AUTO_SLEEP_TIME(0),
      .BYTE_WRITE_WIDTH_A(64),
      .BYTE_WRITE_WIDTH_B(64),
      .CASCADE_HEIGHT(0),
      .CLOCKING_MODE("common_clock"),
      .ECC_MODE("no_ecc"),
      .MEMORY_INIT_FILE("none"),
      .MEMORY_INIT_PARAM("0"),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE("ultra"),
      .MEMORY_SIZE(UDEPTH * 64),
      .MESSAGE_CONTROL(0),
      .READ_DATA_WIDTH_A(64),
      .READ_DATA_WIDTH_B(64),
      .READ_LATENCY_A(3),
      .READ_LATENCY_B(3),
      .READ_RESET_VALUE_A("0"),
      .READ_RESET_VALUE_B("0"),
      .RST_MODE_A("SYNC"),
      .RST_MODE_B("SYNC"),
      .SIM_ASSERT_CHK(0),
      .USE_EMBEDDED_CONSTRAINT(0),
      .USE_MEM_INIT(0),
      .WAKEUP_TIME("disable_sleep"),
      .WRITE_DATA_WIDTH_A(64),
      .WRITE_DATA_WIDTH_B(64),
      .WRITE_MODE_A("no_change"),
      .WRITE_MODE_B("no_change")
  ) u_uram (
      .sleep         (1'b0),
      .clka          (clk),
      .rsta          (~rstn),
      .ena           (ena),
      .regcea        (1'b1),
      .wea           (wea),
      .addra         (addra),
      .dina          (dia),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0),
      .douta         (doa),
      .sbiterra      (),
      .dbiterra      (),
      .clkb          (clk),
      .rstb          (~rstn),
      .enb           (enb),
      .regceb        (1'b1),
      .web           (web),
      .addrb         (addrb),
      .dinb          (dib),
      .injectsbiterrb(1'b0),
      .injectdbiterrb(1'b0),
      .doutb         (dob),
      .sbiterrb      (),
      .dbiterrb      ()
  );

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st0 <= ST_IDLE;
      st1 <= ST_IDLE;
      rd0_v <= '0;
      rd1_v <= '0;
      rd0_hi <= '0;
      rd1_hi <= '0;
      host_rvalid <= 1'b0;
      host_dout <= '0;
      wr1_host <= 1'b0;
      host_rd_v <= '0;
      host_rd_hi <= '0;
    end else begin
      rd0_v  <= {rd0_v[1:0], s0_ar_fire};
      rd0_hi <= {rd0_hi[1:0], s0_ar_widx[0]};
      if (s0_ar_fire) begin
        rid0_s[0] <= s0_axi_arid;
        rd0_uaddr <= s0_ar_widx[WORD_AW-1:1];
      end
      rid0_s[1] <= rid0_s[0];
      rid0_s[2] <= rid0_s[1];

      rd1_v  <= {rd1_v[1:0], s1_ar_fire};
      rd1_hi <= {rd1_hi[1:0], s1_ar_widx[0]};
      if (s1_ar_fire) begin
        rid1_s[0] <= s1_axi_arid;
        rd1_uaddr <= s1_ar_widx[WORD_AW-1:1];
      end
      rid1_s[1] <= rid1_s[0];
      rid1_s[2] <= rid1_s[1];
      host_rd_v  <= {host_rd_v[1:0], host_en && !host_wr && (st1 == ST_IDLE)};
      host_rd_hi <= {host_rd_hi[1:0], host_addr[2]};

      unique case (st0)
        ST_IDLE: begin
          if (s0_wr_fire) begin
            st0    <= ST_R1;
            widx0  <= s0_aw_widx;
            wdata0 <= s0_axi_wdata;
            wstrb0 <= s0_axi_wstrb;
            bid0   <= s0_axi_awid;
          end
        end
        ST_R1: st0 <= ST_R2;
        ST_R2: st0 <= ST_R3;
        ST_R3: begin
          old0 <= doa;
          st0  <= ST_WR;
        end
        ST_WR: st0 <= ST_B;
        ST_B:  if (s0_axi_bready) st0 <= ST_IDLE;
        default: st0 <= ST_IDLE;
      endcase

      unique case (st1)
        ST_IDLE: begin
          if (host_en && host_wr) begin
            st1      <= ST_R1;
            wr1_host <= 1'b1;
            widx1    <= host_addr[WORD_AW+1:2];
            wdata1   <= host_din;
            wstrb1   <= host_wstrb;
          end else if (s1_wr_fire) begin
            st1      <= ST_R1;
            wr1_host <= 1'b0;
            widx1    <= s1_aw_widx;
            wdata1   <= s1_axi_wdata;
            wstrb1   <= s1_axi_wstrb;
            bid1     <= s1_axi_awid;
          end
        end
        ST_R1: st1 <= ST_R2;
        ST_R2: st1 <= ST_R3;
        ST_R3: begin
          old1 <= dob;
          st1  <= ST_WR;
        end
        ST_WR: st1 <= ST_B;
        ST_B:  if (wr1_host || s1_axi_bready) st1 <= ST_IDLE;
        default: st1 <= ST_IDLE;
      endcase

      host_rvalid <= host_rd_v[2];
      if (host_rd_v[2]) begin
        host_dout <= host_rd_hi[2] ? dob[63:32] : dob[31:0];
      end
    end
  end

  assign s0_axi_rvalid = rd0_v[2];
  assign s0_axi_rdata  = rd0_hi[2] ? doa[63:32] : doa[31:0];
  assign s0_axi_rid    = rid0_s[2];
  assign s0_axi_rresp  = 2'b00;
  assign s0_axi_rlast  = 1'b1;
  assign s0_axi_bvalid = (st0 == ST_B);
  assign s0_axi_bid    = bid0;
  assign s0_axi_bresp  = 2'b00;

  assign s1_axi_rvalid = rd1_v[2] && !host_en;
  assign s1_axi_rdata  = rd1_hi[2] ? dob[63:32] : dob[31:0];
  assign s1_axi_rid    = rid1_s[2];
  assign s1_axi_rresp  = 2'b00;
  assign s1_axi_rlast  = 1'b1;
  assign s1_axi_bvalid = (st1 == ST_B) && !host_en;
  assign s1_axi_bid    = bid1;
  assign s1_axi_bresp  = 2'b00;
  assign host_wdone    = (st1 == ST_B) && wr1_host;

  logic unused = &{1'b0, s0_axi_arlen, s0_axi_arsize, s0_axi_arburst, s0_axi_awlen,
                   s0_axi_awsize, s0_axi_awburst, s0_axi_wlast,
                   s1_axi_arlen, s1_axi_arsize, s1_axi_arburst, s1_axi_awlen,
                   s1_axi_awsize, s1_axi_awburst, s1_axi_wlast};

endmodule
