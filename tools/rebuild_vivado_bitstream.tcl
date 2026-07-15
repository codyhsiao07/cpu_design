if { $argc < 3 } {
  puts "Usage: rebuild_vivado_bitstream.tcl <project.xpr> <output.bit> <jobs>"
  exit 2
}

set project_path [file normalize [lindex $argv 0]]
set output_bit   [file normalize [lindex $argv 1]]
set jobs         [lindex $argv 2]

proc require_run_complete {run_name} {
  set run_obj [get_runs $run_name]
  set status [get_property STATUS $run_obj]
  set progress [get_property PROGRESS $run_obj]
  puts "RUN_STATUS $run_name status={$status} progress={$progress}"
  if {$progress ne "100%" || [string first "Complete" $status] < 0} {
    error "$run_name did not complete successfully: $status ($progress)"
  }
}

open_project $project_path
update_compile_order -fileset sources_1

set top_name [get_property TOP [get_filesets sources_1]]
set part_name [get_property PART [current_project]]
puts "PROJECT_TOP $top_name"
puts "PROJECT_PART $part_name"
if {$top_name ne "board_top"} {
  error "Expected non-VGA top board_top, got $top_name"
}

foreach required_tail {uart_bootloader.v icache_pipeline_top.v board_top.v Nexys-A7-100T-Master.xdc} {
  set matches [get_files -quiet *$required_tail]
  if {[llength $matches] == 0} {
    error "Project is missing required source $required_tail"
  }
  puts "PROJECT_SOURCE $required_tail => [lindex $matches 0]"
}

# Reset only generated run products. Source files and project configuration are
# preserved; implementation is rebuilt against the current workspace RTL.
reset_run impl_1
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
require_run_complete synth_1

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
require_run_complete impl_1

# Vivado can report "write_bitstream Complete" even when setup timing is
# violated.  Never publish that image as the board default.
open_run impl_1
set setup_paths [get_timing_paths -setup -max_paths 1]
set hold_paths  [get_timing_paths -hold -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
  error "Implementation completed without setup/hold timing paths"
}
set setup_wns [get_property SLACK [lindex $setup_paths 0]]
set hold_whs  [get_property SLACK [lindex $hold_paths 0]]
puts "FINAL_TIMING setup_wns={$setup_wns} hold_whs={$hold_whs}"
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
  error "Refusing to publish timing-violating bitstream: WNS=$setup_wns WHS=$hold_whs"
}

set project_dir [file dirname $project_path]
set bit_candidates [glob -nocomplain [file join $project_dir *.runs impl_1 *.bit]]
if {[llength $bit_candidates] != 1} {
  error "Expected one implementation bitstream, found [llength $bit_candidates]: $bit_candidates"
}

file mkdir [file dirname $output_bit]
file copy -force [lindex $bit_candidates 0] $output_bit
puts "BITSTREAM_OUTPUT $output_bit"
close_project
exit 0
