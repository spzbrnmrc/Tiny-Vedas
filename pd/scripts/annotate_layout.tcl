# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Color core / GEMM / vector and write an annotated snapshot.
# Env: PD_ANNOTATE_ODB PD_ANNOTATE_PNG PD_ANNOTATE_HIER

set odb_path $::env(PD_ANNOTATE_ODB)
set png_path $::env(PD_ANNOTATE_PNG)
set hier_path ""
if {[info exists ::env(PD_ANNOTATE_HIER)]} {
  set hier_path $::env(PD_ANNOTATE_HIER)
}

if {![file exists $odb_path]} {
  puts "error: missing odb $odb_path"
  exit 1
}

read_db $odb_path

proc _find_name {patterns} {
  foreach pat $patterns {
    set hits [get_cells -quiet -hierarchical $pat]
    if {[llength $hits] > 0} {
      return [get_full_name [lindex $hits 0]]
    }
  }
  return ""
}

proc _cell_stats {name} {
  if {$name eq ""} {
    return [list 0 0.0]
  }
  set cells [get_cells -quiet -hierarchical ${name}/*]
  set n 0
  set area 0.0
  set block [ord::get_db_block]
  set dbu [[ord::get_db_block] getDbUnitsPerMicron]
  foreach c $cells {
    set iname [get_full_name $c]
    set inst [$block findInst $iname]
    if {$inst eq "NULL"} { continue }
    set m [$inst getMaster]
    if {$m eq "NULL"} { continue }
    if {[$m isFiller]} { continue }
    set box [$m getBBox]
    set w [expr {([$box xMax] - [$box xMin]) / double($dbu)}]
    set h [expr {([$box yMax] - [$box yMin]) / double($dbu)}]
    set area [expr {$area + $w * $h}]
    incr n
  }
  return [list $n $area]
}

set core_n [_find_name {u_core}]
set gemm_n [_find_name {u_gemm}]
set vec_n  [_find_name {
  u_core/g_vector.vector_top_inst
  u_core/g_vector_vector_top_inst
  *vector_top_inst*
  *vector_top*
}]

puts "ANNOTATE core=$core_n gemm=$gemm_n vector=$vec_n"

gui::clear_highlights -1
if {$core_n ne ""} { gui::highlight_inst $core_n 0 }
if {$gemm_n ne ""} { gui::highlight_inst $gemm_n 1 }
if {$vec_n  ne ""} { gui::highlight_inst $vec_n  2 }

file mkdir [file dirname $png_path]
save_image -resolution 0.02 $png_path
puts "ANNOTATE_IMAGE $png_path"

if {$hier_path ne ""} {
  lassign [_cell_stats $core_n] core_ncells core_area
  lassign [_cell_stats $gemm_n] gemm_ncells gemm_area
  lassign [_cell_stats $vec_n]  vec_ncells  vec_area
  set core_excl [expr {$core_area - $vec_area}]
  set core_excl_n [expr {$core_ncells - $vec_ncells}]
  set fh [open $hier_path w]
  puts $fh "module,instance,cell_area_um2,hier_cells"
  puts $fh [format "core,%s,%.4f,%d" $core_n $core_area $core_ncells]
  puts $fh [format "core_excl_vector,%s,%.4f,%d" $core_n $core_excl $core_excl_n]
  puts $fh [format "vector,%s,%.4f,%d" $vec_n $vec_area $vec_ncells]
  puts $fh [format "gemm,%s,%.4f,%d" $gemm_n $gemm_area $gemm_ncells]
  close $fh
  puts "ANNOTATE_HIER $hier_path"
  puts [format "AREA core=%.3f um2 / %d cells (excl vector %.3f / %d)" \
    $core_area $core_ncells $core_excl $core_excl_n]
  puts [format "AREA vector=%.3f um2 / %d cells" $vec_area $vec_ncells]
  puts [format "AREA gemm=%.3f um2 / %d cells" $gemm_area $gemm_ncells]
}
