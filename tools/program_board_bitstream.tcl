if { $argc < 1 } {
  puts "Usage: program_board_bitstream.tcl <image.bit>"
  exit 2
}

set bit_path [file normalize [lindex $argv 0]]
if {![file exists $bit_path]} {
  error "Bitstream not found: $bit_path"
}

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet *]
puts "AVAILABLE_HW_TARGETS count=[llength $targets] targets={$targets}"
if {[llength $targets] == 0} {
  error "No JTAG hw_target found. Close any Hardware Manager currently holding the cable and verify board power."
}
set target [lindex $targets 0]
current_hw_target $target
open_hw_target $target
set devices [get_hw_devices -quiet xc7a100t*]
if {[llength $devices] == 0} {
  error "No xc7a100t device found on the JTAG chain"
}
set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bit_path $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
puts "PROGRAMMED_DEVICE $device"
puts "PROGRAMMED_BITSTREAM $bit_path"
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
