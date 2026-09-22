# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Create the Alveo U280 QDMA + Tiny-Vedas FPGA SoC block design (Slice B).
# Expected to be sourced from build.tcl with BOARD_DIR and WORK_DIR set.

proc tv_create_pcie_bd {} {
  global BOARD_DIR

  set soc_v [file normalize "$BOARD_DIR/rtl/vedas_fpga_soc_bd.v"]
  if {![file exists $soc_v]} {
    error "Missing $soc_v"
  }

  create_bd_design pcie_bd
  current_bd_design pcie_bd

  # --- QDMA ---
  set qdma [create_bd_cell -type ip -vlnv xilinx.com:ip:qdma:5.0 qdma_0]
  set_property -dict [list \
    CONFIG.mode_selection {Basic} \
    CONFIG.dma_intf_sel_qdma {AXI_MM} \
    CONFIG.MAILBOX_ENABLE {true} \
    CONFIG.SRIOV_CAP_ENABLE {true} \
    CONFIG.pl_link_cap_max_link_width {X16} \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
    CONFIG.axisten_freq {250} \
  ] $qdma

  # 2 MiB AXI-Lite BAR2: CTRL + ICCM + 1 MiB DCCM (see vedas_fpga_soc.sv)
  set_property CONFIG.pf0_bar2_enabled_qdma {false} $qdma
  set_property -dict [list \
    CONFIG.axilite_master_en {true} \
    CONFIG.pf0_bar2_enabled_qdma {true} \
    CONFIG.pf0_bar2_type_qdma {AXI_Lite_Master} \
    CONFIG.pf0_bar2_scale_qdma {Megabytes} \
    CONFIG.pf0_bar2_size_qdma {2} \
    CONFIG.axilite_master_scale {Megabytes} \
    CONFIG.axilite_master_size {2} \
    CONFIG.barlite2 {2} \
  ] $qdma

  # --- PCIe refclk IBUFDS ---
  set refbuf [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0]
  set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] $refbuf

  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 pcie_refclk
  set_property CONFIG.FREQ_HZ 100000000 [get_bd_intf_ports pcie_refclk]
  connect_bd_intf_net [get_bd_intf_ports pcie_refclk] [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]
  connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_DS_ODIV2] [get_bd_pins qdma_0/sys_clk]
  connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins qdma_0/sys_clk_gt]

  make_bd_intf_pins_external [get_bd_intf_pins qdma_0/pcie_mgt]
  set_property name pci_express [get_bd_intf_ports pcie_mgt_0]

  create_bd_port -dir I -type rst sys_rst_n
  set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports sys_rst_n]
  connect_bd_net [get_bd_ports sys_rst_n] [get_bd_pins qdma_0/sys_rst_n]

  set const_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_1]
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $const_1
  connect_bd_net [get_bd_pins xlconstant_1/dout] [get_bd_pins qdma_0/tm_dsc_sts_rdy]
  connect_bd_net [get_bd_pins xlconstant_1/dout] [get_bd_pins qdma_0/qsts_out_rdy]

  # --- 80 MHz core clock from QDMA axi_aclk (~250 MHz) ---
  set clkwiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
  set_property -dict [list \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {250.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {80.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} \
    CONFIG.RESET_PORT {resetn} \
  ] $clkwiz
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins clk_wiz_0/clk_in1]
  connect_bd_net [get_bd_pins qdma_0/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]

  # --- AXI-Lite → vedas_fpga_soc ---
  set axil_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_axil]
  set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $axil_ic

  connect_bd_intf_net [get_bd_intf_pins qdma_0/M_AXI_LITE] [get_bd_intf_pins axi_ic_axil/S00_AXI]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] \
    [get_bd_pins axi_ic_axil/ACLK] \
    [get_bd_pins axi_ic_axil/S00_ACLK] \
    [get_bd_pins axi_ic_axil/M00_ACLK]
  connect_bd_net [get_bd_pins qdma_0/axi_aresetn] \
    [get_bd_pins axi_ic_axil/ARESETN] \
    [get_bd_pins axi_ic_axil/S00_ARESETN] \
    [get_bd_pins axi_ic_axil/M00_ARESETN]

  # Module reference: Verilog wrapper around SV SoC (BD forbids SV tops)
  set soc [create_bd_cell -type module -reference vedas_fpga_soc_bd vedas_fpga_soc_0]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_axil/M00_AXI] [get_bd_intf_pins vedas_fpga_soc_0/s_axi]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins vedas_fpga_soc_0/s_axi_aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aresetn] [get_bd_pins vedas_fpga_soc_0/s_axi_aresetn]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins vedas_fpga_soc_0/core_clk]
  connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins vedas_fpga_soc_0/core_clk_locked]
  # Help BD / timing report the core domain frequency
  set_property CONFIG.FREQ_HZ 80000000 [get_bd_pins vedas_fpga_soc_0/core_clk]

  # --- AXI-MM stub BRAM (QDMA AXI_MM mode requires M_AXI connected) ---
  set mm_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_mm]
  set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $mm_ic
  connect_bd_intf_net [get_bd_intf_pins qdma_0/M_AXI] [get_bd_intf_pins axi_ic_mm/S00_AXI]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] \
    [get_bd_pins axi_ic_mm/ACLK] \
    [get_bd_pins axi_ic_mm/S00_ACLK] \
    [get_bd_pins axi_ic_mm/M00_ACLK]
  connect_bd_net [get_bd_pins qdma_0/axi_aresetn] \
    [get_bd_pins axi_ic_mm/ARESETN] \
    [get_bd_pins axi_ic_mm/S00_ARESETN] \
    [get_bd_pins axi_ic_mm/M00_ARESETN]

  set mm_bram_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_mm]
  set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH {512} \
  ] $mm_bram_ctrl
  set mm_bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 blk_mem_gen_mm]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_mm/M00_AXI] [get_bd_intf_pins axi_bram_ctrl_mm/S_AXI]
  connect_bd_net [get_bd_pins qdma_0/axi_aclk] [get_bd_pins axi_bram_ctrl_mm/s_axi_aclk]
  connect_bd_net [get_bd_pins qdma_0/axi_aresetn] [get_bd_pins axi_bram_ctrl_mm/s_axi_aresetn]
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_mm/BRAM_PORTA] [get_bd_intf_pins blk_mem_gen_mm/BRAM_PORTA]

  assign_bd_address -offset 0x00000000 -range 0x00200000 -target_address_space \
    [get_bd_addr_spaces qdma_0/M_AXI_LITE] [get_bd_addr_segs vedas_fpga_soc_0/s_axi/reg0] -force
  assign_bd_address -offset 0x00000000 -range 0x00040000 -target_address_space \
    [get_bd_addr_spaces qdma_0/M_AXI] [get_bd_addr_segs axi_bram_ctrl_mm/S_AXI/Mem0] -force

  # ILA on core_clk: GEMM CSR/DMA/PE/status (capture a 128x128x128 run)
  set ila [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_gemm]
  set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {1} \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_PROBE0_WIDTH {16} \
    CONFIG.C_TRIGOUT_EN {false} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
  ] $ila
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ila_gemm/clk]
  connect_bd_net [get_bd_pins vedas_fpga_soc_0/gemm_ila] [get_bd_pins ila_gemm/probe0]

  validate_bd_design
  save_bd_design

  # Global synth with the top — OOC packaging drops include_dirs and breaks
  # generated rv32im_decoder (needs decode_out_t.svh).
  set_property synth_checkpoint_mode None [get_files pcie_bd.bd]

  set wrapper [make_wrapper -files [get_files pcie_bd.bd] -top]
  add_files -norecurse $wrapper
  set_property top pcie_bd_wrapper [current_fileset]
  update_compile_order -fileset sources_1
}
