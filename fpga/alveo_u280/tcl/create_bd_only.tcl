# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Create BD only (no synth/impl) for a fast sanity check.

if {$argc < 2} {
  puts "Usage: create_bd_only.tcl <board_dir> <work_dir>"
  exit 1
}

set BOARD_DIR [file normalize [lindex $argv 0]]
set WORK_DIR  [file normalize [lindex $argv 1]]
set PART      xcu280-fsvh2892-2L-e
set PROJ      [file normalize [file join $BOARD_DIR ../..]]
set FPGA_INC  [file normalize [file join $WORK_DIR include]]

file mkdir $WORK_DIR
cd $WORK_DIR

set FPGA_INC [file normalize [file join $WORK_DIR include]]
if {![file exists [file join $FPGA_INC global.svh]]} {
  error "Missing $FPGA_INC/global.svh — run: make -C $BOARD_DIR config"
}

source [file join $BOARD_DIR tcl create_bd.tcl]

create_project tiny_vedas_u280 $WORK_DIR/vivado -part $PART -force
set_property target_language Verilog [current_project]
set_property include_dirs [list $FPGA_INC \
  [file join $PROJ rtl include] \
  [file join $PROJ rtl idu] \
  [file join $PROJ rtl csr]] \
  [current_fileset]
set_property verilog_define [list SYNTHESIS] [current_fileset]

set flist [file join $BOARD_DIR rtl vedas_fpga.flist]
set fh [open $flist r]
set rtl_files {}
while {[gets $fh line] >= 0} {
  set line [string trim $line]
  if {$line eq "" || [string match "#*" $line]} { continue }
  set line [string map [list \$PROJ $PROJ \$FPGA_INC $FPGA_INC \$BOARD_DIR $BOARD_DIR] $line]
  if {![file exists $line]} { error "Missing: $line" }
  if {[string match "*.svh" $line]} { continue }
  lappend rtl_files $line
}
close $fh
add_files -norecurse $rtl_files
# Headers required for BD module-reference elaboration
set hdr_files [glob -nocomplain \
  [file join $FPGA_INC *.svh] \
  [file join $PROJ rtl include *.svh] \
  [file join $PROJ rtl idu *.svh] \
  [file join $PROJ rtl csr *.svh]]
if {[llength $hdr_files] > 0} {
  add_files -norecurse $hdr_files
}
foreach f [concat $rtl_files $hdr_files] {
  if {[string match "*decode_out_t.svh" $f] || [string match "*csr_pkg.svh" $f]} {
    set_property file_type SystemVerilog [get_files $f]
  } elseif {[string match "*.sv" $f]} {
    set_property file_type SystemVerilog [get_files $f]
  } elseif {[string match "*.svh" $f]} {
    set_property file_type {Verilog Header} [get_files $f]
  }
}
update_compile_order -fileset sources_1

tv_create_pcie_bd
puts "BD OK: $WORK_DIR/vivado"
exit 0
