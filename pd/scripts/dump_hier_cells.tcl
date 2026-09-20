# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Dump leaf-cell bboxes classified as CORE / VECTOR / GEMM / OTHER.
# Env: PD_ANNOTATE_ODB PD_ANNOTATE_CELLS

read_db $::env(PD_ANNOTATE_ODB)

set out $::env(PD_ANNOTATE_CELLS)
file mkdir [file dirname $out]
set fh [open $out w]
puts $fh "label,name,x0,y0,x1,y1,area_um2"

set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]
set counts [dict create CORE 0 VECTOR 0 GEMM 0 OTHER 0]
set areas  [dict create CORE 0.0 VECTOR 0.0 GEMM 0.0 OTHER 0.0]

foreach inst [$block getInsts] {
  set master [$inst getMaster]
  if {$master eq "NULL"} { continue }
  if {[$master isFiller]} { continue }
  set name [$inst getName]
  if {[string match {FILLER_*} $name]} { continue }
  if {[string match {TAPCELL*} $name]} { continue }
  if {[string match {PHY_*} $name]} { continue }

  set box [$inst getBBox]
  if {$box eq "NULL"} { continue }
  set x0 [expr {[$box xMin] / double($dbu)}]
  set y0 [expr {[$box yMin] / double($dbu)}]
  set x1 [expr {[$box xMax] / double($dbu)}]
  set y1 [expr {[$box yMax] / double($dbu)}]
  set area [expr {($x1 - $x0) * ($y1 - $y0)}]

  set label OTHER
  if {[string match {u_core/g_vector*} $name] || [string match {*vector_top_inst*} $name]} {
    set label VECTOR
  } elseif {[string match {u_core*} $name]} {
    set label CORE
  } elseif {[string match {u_gemm*} $name]} {
    set label GEMM
  }

  puts $fh [format "%s,%s,%.4f,%.4f,%.4f,%.4f,%.6f" $label $name $x0 $y0 $x1 $y1 $area]
  dict incr counts $label
  dict set areas $label [expr {[dict get $areas $label] + $area}]
}

close $fh
puts "DUMP_CELLS $out"
foreach lab {CORE VECTOR GEMM OTHER} {
  puts [format "AREA %s %.4f um2 / %d cells" $lab [dict get $areas $lab] [dict get $counts $lab]]
}
