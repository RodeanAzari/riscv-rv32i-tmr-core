# Open the board design in the Vivado GUI, set up for looking at it.
#
#   vivado -mode gui -source syn/gui_view.tcl -tclargs routed [part]
#   vivado -mode gui -source syn/gui_view.tcl -tclargs rtl <part> [tmr]
#   vivado -mode gui -source syn/gui_view.tcl -tclargs ila <part> <bit> <ltx> <pc>
#   vivado -mode gui -source syn/gui_view.tcl -tclargs array|pair <part>
#
# routed (default): the placed and routed checkpoint from the last
#   `make impl`. The Device view shows where every cell landed, colored by
#   module (legend printed to the Tcl console), the worst setup path is
#   selected and drawn in yellow, and its schematic, the timing summary, the
#   utilization by hierarchy and a vectorless power estimate open as tabs.
# rtl: the elaborated design: the RTL as adders, muxes, comparators and
#   registers, before synthesis maps it onto LUTs. Reads rtl/ the way
#   impl_arty.tcl does; tmr = 1 elaborates the TMR core, as make impl TMR=1.
# ila: programs an ILA build on the board and shows a capture as waveforms,
#   triggered when the instruction at <pc> (hex) enters EX.
# array: the 16x16 systolic array's routed checkpoint from make synth-array,
#   coloured by array row, with the worst path, timing and utilization tabs.
# pair: one systolic_pe_pair (two MACs on one DSP48E1) as elaborated RTL.
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
    set tmr [lindex $argv 2]
    if {$tmr eq ""} { set tmr 0 }
    synth_design -rtl -top arty_a7_top -part $part -generic "TMR=$tmr"
    show_schematic [get_cells u_soc/g_cpu.u_core]
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
if {$view eq "pair"} {
    read_verilog -sv [find_sv [file join $repo rtl]]
    synth_design -rtl -top systolic_pe_pair -part $part
    show_schematic [get_cells]
    return
}
if {$view eq "array"} {
    # The 16x16 array out of context (make synth-array): cells coloured by
    # array row, so the systolic structure shows, skew and deskew in grey;
    # no row is yellow, the worst path's colour.
    # Names are flat (synthesis flattened the hierarchy), so match prefixes.
    set dcp [file join $repo syn build array16x16 post_route.dcp]
    if {![file exists $dcp]} { error "$dcp not found -- run make synth-array first" }
    open_checkpoint $dcp
    set rgbs {
        {255   0   0} {255 128   0} {150 100  50} {128 255   0}
        {  0 255   0} {  0 255 128} {  0 255 255} {  0 128 255}
        {  0   0 255} {128   0 255} {255   0 255} {255   0 128}
        {255 160 160} {160 255 160} {160 160 255} {255 255 255}}
    array set rows {}
    set other {}
    foreach c [get_cells -hier -filter {IS_PRIMITIVE}] {
        if {[regexp {^g_row\[(\d+)\]\.} $c -> r]} { lappend rows($r) $c } \
        elseif {![string match {[GV][NC][DC]} $c]} { lappend other $c }
    }
    puts "\n--- Device view colors ---"
    foreach r [lsort -integer [array names rows]] {
        highlight_objects -rgb [lindex $rgbs $r] [get_cells $rows($r)]
        puts [format "  %-14s %5d cells  row %d" "rgb([lindex $rgbs $r])" [llength $rows($r)] $r]
    }
    highlight_objects -rgb {128 128 128} [get_cells $other]
    puts [format "  %-14s %5d cells  input skew, output deskew, valid" "rgb(128 128 128)" [llength $other]]
    set worst [get_timing_paths -max_paths 1 -nworst 1 -setup]
    highlight_objects -color yellow $worst
    select_objects $worst
    puts "  yellow: worst setup path, slack [get_property SLACK $worst] ns"
    show_schematic -name worst_path [get_cells -of_objects $worst]
    report_timing_summary -name timing_summary
    report_utilization -name utilization
    report_utilization -hierarchical -name utilization_hierarchy
    return
}
if {$view ne "routed"} { error "view '$view': expected routed, rtl, ila, array or pair" }

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
