if { $argc < 10 } {
  puts "Usage: impl_one_shot.tcl <part> <top> <synth_dcp> <mig_xci> <mig_example_xdc> <board_xdc> <out_dir> <seed_tag> <place_dir> <route_dir> [physopt_dir] [post_route_physopt_dir]"
  exit 2
}

set part             [lindex $argv 0]
set top_name         [lindex $argv 1]
set synth_dcp        [lindex $argv 2]
set mig_xci          [lindex $argv 3]
set mig_example_xdc  [lindex $argv 4]
set board_xdc        [lindex $argv 5]
set out_dir          [lindex $argv 6]
set seed             [lindex $argv 7]
set place_dir        [lindex $argv 8]
set route_dir        [lindex $argv 9]
set physopt_dir      "AggressiveExplore"
set post_physopt_dir "None"
if { $argc >= 11 } {
  set physopt_dir [lindex $argv 10]
}
if { $argc >= 12 } {
  set post_physopt_dir [lindex $argv 11]
}

file mkdir $out_dir

create_project -in_memory -part $part
set_param project.singleFileAddWarning.threshold 0

add_files -quiet $synth_dcp
read_ip -quiet $mig_xci
read_xdc $mig_example_xdc
read_xdc $board_xdc

link_design -top $top_name -part $part
opt_design
place_design -directive $place_dir
phys_opt_design -directive $physopt_dir
route_design -directive $route_dir
# Vivado 2020.2 does not provide a standalone post-route physopt command
# in this Tcl mode, so keep this script limited to pre-route physopt.

set timing_rpt [file join $out_dir "timing_summary.rpt"]
set util_rpt   [file join $out_dir "utilization.rpt"]
set dcp_out    [file join $out_dir "routed.dcp"]
set res_out    [file join $out_dir "result.txt"]

report_timing_summary -max_paths 20 -warn_on_violation -file $timing_rpt
report_utilization -file $util_rpt
write_checkpoint -force $dcp_out

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set hs  [get_property SLACK [get_timing_paths -hold  -max_paths 1]]
set neg_paths [get_timing_paths -setup -slack_lesser_than 0 -max_paths 100000]
set tns 0.0
foreach p $neg_paths {
  set tns [expr {$tns + [get_property SLACK $p]}]
}

set fp [open $res_out w]
puts $fp "WNS=$wns"
puts $fp "TNS=$tns"
puts $fp "WHS=$hs"
puts $fp "SETUP_FAIL_ENDPOINTS=[llength $neg_paths]"
puts $fp "SEED=$seed"
puts $fp "PLACE_DIRECTIVE=$place_dir"
puts $fp "ROUTE_DIRECTIVE=$route_dir"
puts $fp "PHYSOPT_DIRECTIVE=$physopt_dir"
puts $fp "POST_ROUTE_PHYSOPT_DIRECTIVE=$post_physopt_dir"
close $fp

exit 0
