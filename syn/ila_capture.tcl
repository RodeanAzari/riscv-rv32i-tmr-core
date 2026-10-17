# Program the board with an ILA build (make impl ILA=1) and capture one
# window of the core's pipeline registers.
#
#   vivado -mode batch -source syn/ila_capture.tcl -tclargs <bit> <ltx> <outdir>
#
# Runs Hardware Manager in batch, through hw_server in WSL: the Arty must be
# attached with usbipd (docs/vivado-setup.md section 6). The capture triggers
# at once rather than on a condition -- whatever the program is doing is a
# pipeline in motion -- and is written as CSV (for scripts/ila_check.py) and
# VCD (for GTKWave or Surfer). For conditional triggers, open the same .bit
# and .ltx in Hardware Manager's GUI.

set bit    [lindex $argv 0]
set ltx    [lindex $argv 1]
set outdir [lindex $argv 2]
foreach f [list $bit $ltx] {
    if {![file exists $f]} { error "$f not found -- run make impl ILA=1 first" }
}
file mkdir $outdir

open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    error "no JTAG target -- is the Arty attached to WSL (usbipd attach)?"
}
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices xc7a100t_*] 0]
current_hw_device $dev

set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE  $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
program_hw_devices $dev
refresh_hw_device $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
if {$ila eq ""} { error "no ILA in the programmed design -- was it built with ILA=1?" }

run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 1 $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file [file join $outdir ila_capture.csv] $data
write_hw_ila_data -force -vcd_file [file join $outdir ila_capture.vcd] $data
puts "capture: [file join $outdir ila_capture.csv] (and .vcd)"

close_hw_target
disconnect_hw_server
