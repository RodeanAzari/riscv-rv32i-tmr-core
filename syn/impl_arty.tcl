# Board-level synthesis, implementation and bitstream for the Arty A7-100T.
#
#   vivado -mode batch -source syn/impl_arty.tcl -tclargs <part> <hex> [ila] [tmr]
#
# Top: rtl/top/arty_a7_top.sv, pins in constr/arty_a7.xdc, the RAM loaded
# from <hex> (sw/build/hello.hex, from `make fw`). Unlike synth_ooc.tcl this
# is in-context: real pins, real clocking through the MMCM, and the paths
# between the core and the block RAM timed for the first time.
#
# With ila = 1, an Integrated Logic Analyzer is attached to the core's
# pipeline registers (marked for debug in arty_a7_top.sv) and the probes file
# Hardware Manager needs is written beside the bitstream. Its reports go to
# the build directory, not docs/reports/: the committed reports, and the
# trend tables transcribed from them, are of the design without debug logic.
#
# The bitstream is written only if every timing path meets: a board that
# fails timing behaves in ways no simulation predicts, and that is a worse
# afternoon than a refusal here.

set part [lindex $argv 0]
set hex  [lindex $argv 1]
set ila  [expr {[lindex $argv 2] eq "1"}]
# tmr = 1: three voted copies of the core (rtl/tmr/riscv_core_tmr.sv), with
# reports named *_board_tmr.* so the single core's stay beside them.
set tmr  [expr {[lindex $argv 3] eq "1"}]
set sfx  [expr {$tmr ? "_board_tmr" : "_board"}]
if {$part eq ""} { set part xc7a100tcsg324-1 }

set top     arty_a7_top
set repo    [file normalize [file join [file dirname [info script]] ..]]
set rundir  [file join $repo syn build board]
set reports [expr {$ila ? [file join $rundir ila_reports] : [file join $repo docs reports]}]
set ila_depth 1024

# A missing $readmemh file is only a warning in Vivado, and the result is a
# bitstream whose RAM holds nothing -- a board that does nothing, for no
# visible reason. Refuse instead.
if {$hex eq "" || ![file exists $hex]} {
    error "RAM image '$hex' not found -- run make fw first"
}
set hex [file normalize $hex]

file mkdir $rundir $reports
cd $rundir

# rtl/ only, walked recursively (as in synth_ooc.tcl). Never tb/models/:
# those are lint stand-ins for the primitives Vivado has for real.
proc find_sv {dir} {
    set out [glob -nocomplain -directory $dir -types f *.sv]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set out [concat $out [find_sv $sub]]
    }
    return [lsort $out]
}

set sv [find_sv [file join $repo rtl]]
if {[llength $sv] == 0} {
    error "no .sv files found under rtl/ -- refusing to synthesize nothing"
}
# DMA-Engine's register package (submodule, generated from its
# spec/dmaeng.yaml) first: packages compile before what imports them.
set sv [concat [list [file join $repo sw dma-engine rtl dmaeng_pkg.sv]] $sv]
read_verilog -sv $sv
read_xdc [file join $repo constr arty_a7.xdc]

synth_design -top $top -part $part -generic "INIT_FILE=\"$hex\"" -generic "ILA=$ila" \
    -generic "TMR=$tmr"

set bb [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
if {[llength $bb] > 0} {
    error "black boxes in the synthesized netlist: $bb"
}

# --- ILA ---------------------------------------------------------------------
# One probe per marked bus, in the order the nets sort, bit 0 first; sampled
# on the core clock. Probe names in Hardware Manager are the net names.
if {$ila} {
    set marked [get_nets -hier -filter {MARK_DEBUG == 1}]
    if {[llength $marked] == 0} { error "ILA=1 but no nets are marked for debug" }
    set buses [dict create]
    foreach n [lsort -dictionary $marked] {
        regsub {\[[0-9]+\]$} $n "" base
        dict lappend buses $base $n
    }
    create_debug_core u_ila ila
    set_property C_DATA_DEPTH        $ila_depth [get_debug_cores u_ila]
    set_property C_INPUT_PIPE_STAGES 0          [get_debug_cores u_ila]
    set_property C_TRIGIN_EN         false      [get_debug_cores u_ila]
    set_property C_TRIGOUT_EN        false      [get_debug_cores u_ila]
    set_property port_width 1 [get_debug_ports u_ila/clk]
    connect_debug_port u_ila/clk [get_nets -of_objects [get_pins u_bufg/O]]
    set i 0
    dict for {base nets} $buses {
        if {$i > 0} { create_debug_port u_ila probe }
        set port [get_debug_ports u_ila/probe$i]
        set_property port_width [llength $nets] $port
        set_property PROBE_TYPE DATA_AND_TRIGGER $port
        connect_debug_port $port $nets
        puts [format "ILA probe%-2d %3d bits  %s" $i [llength $nets] $base]
        incr i
    }
    implement_debug_core
}

write_checkpoint -force [file join $rundir post_synth.dcp]

opt_design
place_design
route_design
write_checkpoint -force [file join $rundir post_route.dcp]

report_utilization    -file [file join $reports utilization$sfx.rpt]
report_timing_summary -file [file join $reports timing$sfx.rpt]

# --- headline numbers -------------------------------------------------------
# The core runs on the MMCM's CLKOUT0. Its slack against that clock's period
# gives the board-level Fmax: 1000 / (period - WNS). Worst setup slack over
# all clocks gates the bitstream.

set clk    [get_clocks -of_objects [get_pins u_mmcm/CLKOUT0]]
set period [get_property PERIOD $clk]
set paths  [get_timing_paths -delay_type max -max_paths 1 -nworst 1 -group $clk]
if {[llength $paths] == 0} { error "no timing paths on the core clock" }
set wns      [get_property SLACK $paths]
set achieved [expr {$period - $wns}]
set fmax     [expr {1000.0 / $achieved}]

set worst [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set hold  [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]

set dev [get_parts $part]
foreach {label group total} [list \
        LUT   LUT         [get_property LUT_ELEMENTS $dev] \
        FF    FLOP_LATCH  [get_property FLIPFLOPS    $dev] \
        BRAM  BMEM        [get_property BLOCK_RAMS   $dev] \
        DSP   MULT        [get_property DSP          $dev] \
        CARRY CARRY       0] {
    set used [llength [get_cells -hier -filter "PRIMITIVE_GROUP == $group"]]
    dict set util $label [list $used $total]
}

set fh [open [file join $reports summary$sfx.txt] w]
foreach out [list stdout $fh] {
    puts $out ""
    puts $out "=== arty_a7_top ([expr {$tmr ? "TMR core" : "core"}] + 32 KiB RAM + LED + UART[expr {$ila ? " + ILA" : ""}]), board-level, post-route ==="
    puts $out [format "part            %s" $part]
    puts $out [format "core clock      %s, %.3f ns (%.1f MHz), MMCM from 100 MHz" \
               [get_property NAME $clk] $period [expr {1000.0/$period}]]
    puts $out [format "WNS (core clk)  %.3f ns" $wns]
    puts $out [format "achieved period %.3f ns" $achieved]
    puts $out [format "Fmax (core clk) %.1f MHz" $fmax]
    puts $out [format "worst setup     %.3f ns (all clocks)" $worst]
    puts $out [format "worst hold      %.3f ns (all clocks)" $hold]
    puts $out ""
    puts $out "In-context: real pins, clock tree and BRAM paths. LED, UART and"
    puts $out "button I/O are false-pathed (constr/arty_a7.xdc). Fmax is what the"
    puts $out "core clock could be at this placement, not a measured run there."
    puts $out ""
    dict for {label pair} $util {
        lassign $pair used total
        if {$total > 0} {
            puts $out [format "%-5s %8d / %8d  (%5.2f%%)" \
                       $label $used $total [expr {100.0*$used/$total}]]
        } else {
            puts $out [format "%-5s %8d %19s" $label $used "(no device total)"]
        }
    }
    puts $out ""
}
close $fh

if {$worst < 0 || $hold < 0} {
    error "timing not met (setup $worst ns, hold $hold ns) -- no bitstream written"
}

set bit [file join $rundir $top.bit]
write_bitstream -force $bit
puts "bitstream: $bit"

# Without ILA, remove a stale probes file so Hardware Manager never pairs
# this bitstream with probes from an earlier ILA build.
set ltx [file join $rundir $top.ltx]
if {$ila} {
    write_debug_probes -force $ltx
    puts "probes:    $ltx"
} else {
    file delete -force $ltx
}
