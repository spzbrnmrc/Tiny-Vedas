# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Program Alveo U280 via JTAG (batch).
# Usage: vivado -mode batch -source tcl/program.tcl -tclargs <bitstream.bit>

if {$argc < 1} {
  error "usage: vivado -mode batch -source program.tcl -tclargs <bitstream.bit>"
}

set BIT [file normalize [lindex $argv 0]]
if {![file exists $BIT]} {
  error "bitstream not found: $BIT"
}

puts "PROGRAM: $BIT"

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
  refresh_hw_server [current_hw_server]
  set targets [get_hw_targets -quiet]
}
if {[llength $targets] == 0} {
  error "no JTAG targets — is the Alveo USB/JTAG cable connected?"
}

# Prefer the first target (U280 on-board FT4232H).
current_hw_target [lindex $targets 0]
open_hw_target

set devices [get_hw_devices]
if {[llength $devices] == 0} {
  error "no hw_devices on target"
}

set hw ""
foreach d $devices {
  if {[string match "*xcu280*" $d]} {
    set hw $d
    break
  }
}
if {$hw eq ""} {
  set hw [lindex $devices 0]
  puts "WARNING: no xcu280* device; using $hw"
}

puts "DEVICE: $hw PART=[get_property PART $hw]"
current_hw_device $hw
refresh_hw_device -update_hw_probes false $hw
set_property PROGRAM.FILE $BIT $hw
program_hw_devices $hw

# Optional: confirm DONE
refresh_hw_device -update_hw_probes false $hw
puts "DONE: programmed $hw with $BIT"

close_hw_target
disconnect_hw_server
close_hw_manager
