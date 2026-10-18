# Open the board design in the Vivado GUI, set up for looking at it.
#
#   vivado -mode gui -source syn/gui_view.tcl -tclargs routed|rtl [part]
#   vivado -mode gui -source syn/gui_view.tcl -tclargs ila <part> <bit> <ltx> <pc>
#
# routed (default): the placed and routed checkpoint from the last
#   `make impl`. The Device view shows where every cell landed, colored by
#   module (legend printed to the Tcl console), the worst setup path is
#   selected and drawn in yellow, and its schematic, the timing summary, the
#   utilization by hierarchy and a vectorless power estimate open as tabs.
# rtl: the elaborated design: the RTL as adders, muxes, comparators and
#   registers, before synthesis maps it onto LUTs. Reads rtl/ the way
#   impl_arty.tcl does.
# ila: programs an ILA build on the board and shows a capture as waveforms,
#   triggered when the instruction at <pc> (hex) enters EX.
#
# For looking only. Nothing here writes to docs/reports/: the committed
# numbers come from the batch flows.

set view [lindex $argv 0]
set part [lindex $argv 1]
if {$view eq ""} { set view routed }
if {$part eq ""} { set part xc7a100tcsg324-1 }
set repo [file normalize [file join [file dirname [info script]] ..]]

proc find_sv {dir} {
    set out [glob -nocomplain -directory $dir -types f *.sv]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set out [concat $out [find_sv $sub]]
    }
    return [lsort $out]
}

if {$view eq "rtl"} {
    read_verilog -sv [find_sv [file join $repo rtl]]
    read_xdc [file join $repo constr arty_a7.xdc]
    synth_design -rtl -top arty_a7_top -part $part
    show_schematic [get_cells u_soc/u_core]
    return
}
if {$view eq "ila"} {
    # Program an ILA build, arm it to trigger when the instruction at <pc>
    # enters EX, and show the capture as waveforms. Re-arm from the GUI's
    # Run Trigger button (press RESET on the board to rerun the program).
    lassign [lrange $argv 2 4] bit ltx pc
    foreach f [list $bit $ltx] {
        if {![file exists $f]} { error "$f not found -- run make impl ILA=1 first" }
    }
    open_hw_manager
    connect_hw_server -url localhost:3121
    if {[llength [get_hw_targets]] == 0} {
        error "no JTAG target -- is the Arty attached to WSL (usbipd attach)?"
    }
    open_hw_target [lindex [get_hw_targets] 0]
    set dev [lindex [get_hw_devices xc7a100t_*] 0]
    current_hw_device $dev
    set_property PROGRAM.FILE $bit $dev
    set_property PROBES.FILE  $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    set ila [lindex [get_hw_ilas -of_objects $dev] 0]
    set_property TRIGGER_COMPARE_VALUE "eq32'h$pc" \
        [get_hw_probes -of_objects $ila -filter {NAME =~ *id_ex_pc_p*}]
    set_property CONTROL.TRIGGER_POSITION 64 $ila
    run_hw_ila $ila
    wait_on_hw_ila -timeout 1 $ila
    display_hw_ila_data [upload_hw_ila_data $ila]
    return
}
if {$view ne "routed"} { error "view '$view': expected routed, rtl or ila" }

set dcp [file join $repo syn build board post_route.dcp]
if {![file exists $dcp]} { error "$dcp not found -- run make impl first" }
open_checkpoint $dcp

# Leaf cells per module, most specific first; a cell takes the first module
# whose name is a prefix of its own. Compared as plain strings: the copies'
# names (g_other[1]) hold brackets, which a get_cells filter reads as a glob.
# A TMR build (make impl TMR=1) is coloured by copy instead.
set core u_soc/g_cpu.u_core
if {[llength [get_cells -quiet $core/u_core_a]]} {
    set modules [list \
        $core/u_core_a           {255 128   0}  "core copy A" \
        "$core/g_other\[1\].u_core" {  0 255   0}  "core copy B" \
        "$core/g_other\[2\].u_core" {  0 200 255}  "core copy C" \
        $core                    {255   0 255}  "voter + mismatch counter"]
} else {
    set modules [list \
        $core/u_alu      {255 128   0}  ALU \
        $core/u_branch   {255   0 255}  "branch compare + target" \
        $core/u_regfile  {  0 200 255}  "register file (LUTRAM)" \
        $core            {  0 255   0}  "rest of core: decode, hazards, pipeline regs"]
}
lappend modules \
    u_soc/u_ram      {255 255 255}  "32 KiB RAM (block RAM)" \
    u_soc/u_uart_tx  {255   0   0}  "UART transmitter" \
    u_soc/u_uart_rx  {255 144 144}  "UART receiver"
array set taken {}
set leaves [get_cells -hier -filter {IS_PRIMITIVE}]
puts "\n--- Device view colors ---"
foreach {hier rgb label} $modules {
    set cells {}
    set p "$hier/"
    foreach c $leaves {
        if {![info exists taken($c)] && [string equal -length [string length $p] $p $c]} {
            set taken($c) 1
            lappend cells $c
        }
    }
    if {[llength $cells]} { highlight_objects -rgb $rgb [get_cells $cells] }
    puts [format "  %-14s %5d cells  %s" "rgb($rgb)" [llength $cells] $label]
}

set worst [get_timing_paths -max_paths 1 -nworst 1 -setup]
highlight_objects -color yellow $worst
select_objects $worst
puts "  yellow: worst setup path, slack [get_property SLACK $worst] ns"
show_schematic -name worst_path [get_cells -of_objects $worst]

report_timing_summary -name timing_summary
report_utilization -name utilization
report_power -name power
