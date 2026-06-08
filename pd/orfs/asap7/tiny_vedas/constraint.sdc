current_design core_top

set clk_name core_clock
set clk_port_name clk
set clk_period __CLK_PERIOD__
set clk_io_pct __CLK_IO_PCT__

set clk_port [get_ports $clk_port_name]

create_clock -name $clk_name -period $clk_period $clk_port

set non_clock_inputs [all_inputs -no_clocks]

set_input_delay  [expr {$clk_period * $clk_io_pct}] -clock $clk_name $non_clock_inputs
set_output_delay [expr {$clk_period * $clk_io_pct}] -clock $clk_name [all_outputs]

set rst_ports [get_ports {rstn reset_vector}]
if {[llength $rst_ports]} {
  set_false_path -from $rst_ports
}
