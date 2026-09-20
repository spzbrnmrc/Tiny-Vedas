///////////////////////////////////////////////////////////////////////////////
//     Copyright (c) 2025 Siliscale Consulting, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
///////////////////////////////////////////////////////////////////////////////
// Slice A: vset* + csrr. Slice B: unit-stride vle32 / vse32.
// Slice C–F: valu beat ALU (arith/logic/minmax/shift + packed-mask cmp).

`ifndef GLOBAL_SVH
`include "global.svh"
`endif

`ifndef TYPES_SVH
`include "types.svh"
`endif

module vector_top (
    input logic clk,
    input logic rstn,

    input idu1_out_t idu1_out,

    input  logic [XLEN-1:0] csr_vl,
    input  logic [XLEN-1:0] csr_vtype,
    input  logic [XLEN-1:0] csr_vlenb,
    input  logic [XLEN-1:0] csr_vstart,
    input  logic [XLEN-1:0] csr_rdata,
    input  logic            csr_illegal,

    output logic            csr_req,
    output logic            csr_write,
    output logic [    11:0] csr_addr,
    output logic [XLEN-1:0] csr_wdata,

    output logic            vset_we,
    output logic [XLEN-1:0] vset_vl,
    output logic [XLEN-1:0] vset_vtype,

    output logic              v_dccm_req,
    output logic              v_dccm_wen,
    output logic [      31:0] v_dccm_addr,
    output logic [     127:0] v_dccm_wdata,
    output logic [      15:0] v_dccm_wstrb,
    input  logic [     127:0] v_dccm_rdata,
    input  logic              v_dccm_rvalid,

    output logic [               XLEN-1:0] wb_data,
    output logic [REG_FILE_ADDR_WIDTH-1:0] wb_rd_addr,
    output logic                           wb_rd_wr_en,
    output logic                           vector_busy
`ifdef TV_HAS_CORE_DEBUG
    ,
    output core_debug_lane_t debug
`endif
);

  localparam int unsigned VLMAX = (VLEN == 0) ? 1 : (VLEN / 32);
  localparam int unsigned BEAT_EL = (DLEN == 0) ? 1 : (DLEN / 32);
  localparam logic [31:0] VTYPE_LEGAL = 32'h000000D0;
  localparam logic [31:0] VTYPE_VILL = 32'h80000000;

  logic issue_vset;
  logic issue_vcsr;
  logic issue_vmem;
  logic issue_valu;
  logic is_vsetvli;
  logic is_vsetivli;
  logic is_vsetvl;
  logic vtype_legal;
  logic rd_is_x0;
  logic rs1_is_x0;

  logic [31:0] req_vtype;
  logic [31:0] avl;
  logic [31:0] vl_new;
  logic [31:0] vtype_new;

  logic [               XLEN-1:0] wb_data_i;
  logic [REG_FILE_ADDR_WIDTH-1:0] wb_rd_addr_i;
  logic                           wb_rd_wr_en_i;

  assign issue_vset = idu1_out.legal && idu1_out.vset;
  assign issue_vcsr = idu1_out.legal && idu1_out.vcsr;
  assign issue_vmem = idu1_out.legal && (idu1_out.vload || idu1_out.vstore);
  assign issue_valu = idu1_out.legal && idu1_out.valu;

  assign is_vsetvli  = issue_vset && !idu1_out.instr[31];
  assign is_vsetivli = issue_vset && (idu1_out.instr[31:30] == 2'b11);
  assign is_vsetvl   = issue_vset && (idu1_out.instr[31:25] == 7'b1000000);

  always_comb begin
    if (is_vsetvl) begin
      req_vtype = idu1_out.rs2_data;
    end else if (is_vsetivli) begin
      req_vtype = {21'd0, idu1_out.instr[29:20]};
    end else begin
      req_vtype = {21'd0, idu1_out.instr[30:20]};
    end
  end

  assign vtype_legal = (req_vtype == VTYPE_LEGAL);
  assign rd_is_x0    = (idu1_out.rd_addr == 5'd0);
  assign rs1_is_x0   = (idu1_out.rs1_addr == 5'd0);

  always_comb begin
    if (is_vsetivli) begin
      avl = {27'd0, idu1_out.instr[19:15]};
    end else if (rd_is_x0 && rs1_is_x0) begin
      avl = csr_vl;
    end else if (!rd_is_x0 && rs1_is_x0) begin
      avl = VLMAX[31:0];
    end else begin
      avl = idu1_out.rs1_data;
    end
  end

  assign vl_new    = vtype_legal ? ((avl < VLMAX[31:0]) ? avl : VLMAX[31:0]) : 32'd0;
  assign vtype_new = vtype_legal ? VTYPE_LEGAL : VTYPE_VILL;

  assign vset_we    = issue_vset;
  assign vset_vl    = vl_new;
  assign vset_vtype = vtype_new;

  assign csr_req   = issue_vcsr;
  assign csr_write = 1'b0;
  assign csr_addr  = idu1_out.instr[31:20];
  assign csr_wdata = 32'd0;

  always_comb begin
    wb_data_i    = 32'd0;
    wb_rd_addr_i = idu1_out.rd_addr;
    wb_rd_wr_en_i = 1'b0;
    if (issue_vset && !rd_is_x0) begin
      wb_data_i     = vl_new;
      wb_rd_wr_en_i = 1'b1;
    end else if (issue_vcsr && !rd_is_x0 && !csr_illegal) begin
      wb_data_i     = csr_rdata;
      wb_rd_wr_en_i = 1'b1;
    end
  end

  register_sync_rstn #(
      .WIDTH($bits({wb_data_i, wb_rd_addr_i, wb_rd_wr_en_i}))
  ) wb_ff (
      .clk (clk),
      .rstn(rstn),
      .din ({wb_data_i, wb_rd_addr_i, wb_rd_wr_en_i}),
      .dout({wb_data, wb_rd_addr, wb_rd_wr_en})
  );

  /* ---- VRF (SVLib flops) + VLSU / VALU lanes (SVLib adder) ---- */
  typedef enum logic [2:0] { V_IDLE, V_REQ, V_WAIT, V_TAIL, V_ALU } vlsu_e;
  vlsu_e st;

  localparam int unsigned VRF_AW = $clog2(32 * VLMAX);
  localparam int unsigned N_RP   = 2 * BEAT_EL;
  localparam int unsigned N_WP   = BEAT_EL;

  logic [4:0]  vd_q;
  logic [4:0]  vs1_q;
  logic [4:0]  vs2_q;
  logic [31:0] addr_q;
  logic [31:0] left_q;
  logic [31:0] elem_q;
  logic [31:0] vl_q;
  logic [31:0] scalar_q;
  logic [2:0]  funct3_q;
  logic [5:0]  funct6_q;
  logic        is_store_q;
  logic [15:0] mask_q;
  logic [15:0] mask_comb;
  logic        is_compare;
  logic        last_alu;

  logic [2:0] slot;
  logic [2:0] n;
  logic [2:0] n_alu;
  logic [2:0] room;

  assign slot = {1'b0, addr_q[3:2]};
  assign room = 3'(BEAT_EL) - slot;
  always_comb begin
    n = room;
    if (left_q < {29'd0, room}) n = left_q[2:0];
  end
  always_comb begin
    n_alu = 3'(BEAT_EL);
    if (left_q < {29'd0, 3'(BEAT_EL)}) n_alu = left_q[2:0];
  end

  function automatic logic [VRF_AW-1:0] vrf_idx(input logic [4:0] v, input logic [4:0] e);
    return VRF_AW'(v) * VRF_AW'(VLMAX) + VRF_AW'(e);
  endfunction

  logic [N_RP-1:0][VRF_AW-1:0] vrf_raddr;
  logic [N_RP-1:0][      31:0] vrf_rdata;
  logic [N_WP-1:0][VRF_AW-1:0] vrf_waddr;
  logic [N_WP-1:0]             vrf_wen;
  logic [N_WP-1:0][      31:0] vrf_wdata;
  logic [N_WP-1:0][      31:0] lane_res;
  logic [N_WP-1:0]             lane_cmp;
  logic [4:0]                  rd_v;

  assign is_compare = (funct6_q[5:3] == 3'b011);
  assign last_alu   = (left_q == {29'd0, n_alu});

  always_comb begin
    mask_comb = mask_q;
    if (st == V_ALU && is_compare) begin
      for (int i = 0; i < BEAT_EL; i++) begin
        if (3'(i) < n_alu) mask_comb[elem_q[3:0] + 4'(i)] = lane_cmp[i];
      end
    end
  end

  assign rd_v = (st == V_REQ && is_store_q) ? vd_q : vs2_q;

  always_comb begin
    for (int i = 0; i < BEAT_EL; i++) begin
      vrf_raddr[i]           = vrf_idx(rd_v, elem_q[4:0] + 5'(i));
      vrf_raddr[BEAT_EL+i]   = vrf_idx(vs1_q, elem_q[4:0] + 5'(i));
    end
  end

  vrf #(
      .N_VREG  (32),
      .VLMAX   (VLMAX),
      .N_RPORTS(N_RP),
      .N_WPORTS(N_WP)
  ) u_vrf (
      .clk  (clk),
      .rstn (rstn),
      .raddr(vrf_raddr),
      .rdata(vrf_rdata),
      .waddr(vrf_waddr),
      .wen  (vrf_wen),
      .wdata(vrf_wdata)
  );

  genvar gi;
  generate
    for (gi = 0; gi < int'(BEAT_EL); gi++) begin : g_lane
      valu_lane u_lane (
          .a      (vrf_rdata[gi]),
          .b      ((funct3_q == 3'b000) ? vrf_rdata[BEAT_EL+gi] : scalar_q),
          .funct6 (funct6_q),
          .result (lane_res[gi]),
          .cmp_bit(lane_cmp[gi])
      );
    end
  endgenerate

  always_comb begin
    v_dccm_wdata = 128'd0;
    v_dccm_wstrb = 16'd0;
    for (int ei = 0; ei < BEAT_EL; ei++) begin
      if (ei >= int'(slot) && ei < int'(slot + n)) begin
        v_dccm_wdata[32*ei+:32] = vrf_rdata[ei-int'(slot)];
        v_dccm_wstrb[4*ei+:4]   = 4'hF;
      end
    end
  end

  assign v_dccm_req  = (st == V_REQ);
  assign v_dccm_wen  = (st == V_REQ) && is_store_q;
  assign v_dccm_addr = {addr_q[31:4], 4'd0};

  always_comb begin
    vrf_wen   = '0;
    vrf_waddr = '0;
    vrf_wdata = '0;
    if (st == V_WAIT && v_dccm_rvalid) begin
      for (int i = 0; i < BEAT_EL; i++) begin
        if (i >= int'(slot) && i < int'(slot + n)) begin
          vrf_wen[i]   = 1'b1;
          vrf_waddr[i] = vrf_idx(vd_q, elem_q[4:0] + 5'(i) - {2'b00, slot});
          vrf_wdata[i] = v_dccm_rdata[32*i+:32];
        end
      end
    end else if (st == V_ALU && is_compare) begin
      if (last_alu) begin
        vrf_wen[0]   = 1'b1;
        vrf_waddr[0] = vrf_idx(vd_q, 5'd0);
        vrf_wdata[0] = {16'hFFFF, mask_comb};
      end
    end else if (st == V_ALU) begin
      for (int i = 0; i < BEAT_EL; i++) begin
        if (3'(i) < n_alu) begin
          vrf_wen[i]   = 1'b1;
          vrf_waddr[i] = vrf_idx(vd_q, elem_q[4:0] + 5'(i));
          vrf_wdata[i] = lane_res[i];
        end
      end
    end else if (st == V_TAIL) begin
      for (int i = 0; i < BEAT_EL; i++) begin
        if (3'(i) < n_alu) begin
          vrf_wen[i]   = 1'b1;
          vrf_waddr[i] = vrf_idx(vd_q, elem_q[4:0] + 5'(i));
          vrf_wdata[i] = 32'hFFFFFFFF;
        end
      end
    end
  end

  logic        vill;
  logic        need_body;
  logic        need_tail;
  logic        valu_body;
  logic [31:0] valu_imm;
  logic [31:0] valu_uimm;
  logic        issue_shift;
  assign vill         = csr_vtype[31];
  assign need_body    = issue_vmem && !vill && (csr_vl != 32'd0);
  assign need_tail    = issue_vmem && !vill && idu1_out.vload;
  assign valu_body    = issue_valu && !vill && (csr_vl != 32'd0);
  assign valu_imm     = {{27{idu1_out.instr[19]}}, idu1_out.instr[19:15]};
  assign valu_uimm    = {27'd0, idu1_out.instr[19:15]};
  assign issue_shift  = (idu1_out.instr[31:26] == 6'b100101) ||
                        (idu1_out.instr[31:26] == 6'b101000) ||
                        (idu1_out.instr[31:26] == 6'b101001);

  assign vector_busy = (st != V_IDLE);

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st         <= V_IDLE;
      vd_q       <= 5'd0;
      vs1_q      <= 5'd0;
      vs2_q      <= 5'd0;
      addr_q     <= 32'd0;
      left_q     <= 32'd0;
      elem_q     <= 32'd0;
      vl_q       <= 32'd0;
      scalar_q   <= 32'd0;
      funct3_q   <= 3'd0;
      funct6_q   <= 6'd0;
      is_store_q <= 1'b0;
      mask_q     <= 16'hFFFF;
    end else begin
      unique case (st)
        V_IDLE: begin
          if (issue_vmem && !vill) begin
            vd_q       <= idu1_out.rd_addr;
            addr_q     <= idu1_out.rs1_data;
            elem_q     <= 32'd0;
            vl_q       <= csr_vl;
            is_store_q <= idu1_out.vstore;
            if (need_body) begin
              left_q <= csr_vl;
              st     <= V_REQ;
            end else if (need_tail) begin
              left_q <= VLMAX[31:0];
              st     <= V_TAIL;
            end
          end else if (issue_valu && !vill) begin
            vd_q     <= idu1_out.rd_addr;
            vs1_q    <= idu1_out.rs1_addr;
            vs2_q    <= idu1_out.rs2_addr;
            elem_q   <= 32'd0;
            vl_q     <= csr_vl;
            funct3_q <= idu1_out.instr[14:12];
            funct6_q <= idu1_out.instr[31:26];
            mask_q   <= 16'hFFFF;
            if (idu1_out.instr[14:12] == 3'b011)
              scalar_q <= issue_shift ? valu_uimm : valu_imm;
            else
              scalar_q <= idu1_out.rs1_data;
            if (valu_body) begin
              left_q <= csr_vl;
              st     <= V_ALU;
            end else begin
              left_q <= VLMAX[31:0];
              st     <= V_TAIL;
            end
          end
        end
        V_REQ: begin
          if (is_store_q) begin
            addr_q <= addr_q + {29'd0, n, 2'b00};
            elem_q <= elem_q + {29'd0, n};
            left_q <= left_q - {29'd0, n};
            if (left_q == {29'd0, n}) st <= V_IDLE;
          end else begin
            st <= V_WAIT;
          end
        end
        V_WAIT: begin
          if (v_dccm_rvalid) begin
            addr_q <= addr_q + {29'd0, n, 2'b00};
            elem_q <= elem_q + {29'd0, n};
            left_q <= left_q - {29'd0, n};
            if (left_q == {29'd0, n}) begin
              if (vl_q < VLMAX[31:0]) begin
                elem_q <= vl_q;
                left_q <= VLMAX[31:0] - vl_q;
                st     <= V_TAIL;
              end else st <= V_IDLE;
            end else st <= V_REQ;
          end
        end
        V_ALU: begin
          if (is_compare) mask_q <= mask_comb;
          elem_q <= elem_q + {29'd0, n_alu};
          left_q <= left_q - {29'd0, n_alu};
          if (last_alu) begin
            if (is_compare && (VLMAX > 1)) begin
              elem_q <= 32'd1;
              left_q <= VLMAX[31:0] - 32'd1;
              st     <= V_TAIL;
            end else if (!is_compare && (vl_q < VLMAX[31:0])) begin
              elem_q <= vl_q;
              left_q <= VLMAX[31:0] - vl_q;
              st     <= V_TAIL;
            end else st <= V_IDLE;
          end
        end
        V_TAIL: begin
          elem_q <= elem_q + {29'd0, n_alu};
          left_q <= left_q - {29'd0, n_alu};
          if (left_q == {29'd0, n_alu}) st <= V_IDLE;
        end
        default: st <= V_IDLE;
      endcase
    end
  end

`ifdef TV_HAS_CORE_DEBUG
  logic [XLEN-1:0] dbg_tag;
  logic [    31:0] dbg_instr;

  register_sync_rstn #(
      .WIDTH(XLEN + 32)
  ) dbg_ff (
      .clk (clk),
      .rstn(rstn),
      .din ({idu1_out.instr_tag, idu1_out.instr}),
      .dout({dbg_tag, dbg_instr})
  );

  always_comb begin
    debug                       = '0;
    debug.reg_wr                = wb_rd_wr_en;
    debug.wb_instr_tag          = dbg_tag;
    debug.wb_instr              = dbg_instr;
    debug.wb_rd_addr            = wb_rd_addr;
    debug.wb_data               = wb_data;
  end
`endif

  logic _unused_csr;
  assign _unused_csr = |{csr_vlenb, csr_vstart};

endmodule
