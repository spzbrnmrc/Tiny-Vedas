# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# opt_design TCL.PRE — clocks exist here. Fail hard if unresolved so we
# don't burn a full U280 route with CDC still timed as sync paths.
#
# Verified clock names (this BD):
#   clk_out1_pcie_bd_clk_wiz_0_0      — MMCM 100 MHz core
#   axi_bram_ctrl_mm_BRAM_PORTA_CLK   — QDMA axi_aclk ~250 MHz

set _core_clk [get_clocks -quiet clk_out1_pcie_bd_clk_wiz_0_0]
set _axi_clk  [get_clocks -quiet axi_bram_ctrl_mm_BRAM_PORTA_CLK]

if {[llength $_core_clk] == 0} {
  set _core_clk [get_clocks -quiet -of_objects [get_pins -quiet -hier *clk_wiz_0*/clk_out1]]
}
if {[llength $_axi_clk] == 0} {
  set _axi_clk [get_clocks -quiet -of_objects [get_pins -quiet -hier *qdma_0*/axi_aclk]]
}

if {[llength $_core_clk] == 0 || [llength $_axi_clk] == 0} {
  error "TIMING_CDC: unresolved clocks (core='$_core_clk' axi='$_axi_clk') — aborting before route"
}

# Related clocks (MMCM child of axi) — false_path both ways; verified on routed DCP.
set_false_path -from $_core_clk -to $_axi_clk
set_false_path -from $_axi_clk  -to $_core_clk
puts "TIMING_CDC: OK false_path {[lindex $_core_clk 0]} <-> {[lindex $_axi_clk 0]}"
