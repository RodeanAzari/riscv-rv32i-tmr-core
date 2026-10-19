# Out-of-context synthesis and implementation of riscv_core on its own, of
# the TMR core (three voted copies, rtl/tmr/riscv_core_tmr.sv), or of the
# systolic array at a given size (rtl/accel/systolic_array.sv, Phase F).
#
#   vivado -mode batch -source syn/synth_ooc.tcl -tclargs <part> [riscv_core_tmr]
#   vivado -mode batch -source syn/synth_ooc.tcl -tclargs <part> systolic_array <rows> <cols>
#
# Reports: docs/reports/*_ooc.* for the core, *_ooc_tmr.* for the TMR core,
# which also gets a per-hierarchy utilization report and a check that three
# copies survived synthesis (CLAUDE.md 5.7: Vivado merges identical logic
# unless told not to), *_ooc_array<rows>x<cols>.* for the array.
#
# Why out-of-context: the core's ports (imem_*, if_id_*) are internal signals
# that will connect to BRAM and downstream stages, not package pins. In-context
# synthesis would insert I/O buffers on all of them and demand pin assignments
# that do not mean anything yet. OOC skips buffer insertion, so the core can be
# measured before a board-level top exists.
#
# Why it runs all the way to route_design: post-synthesis timing is an estimate,
# because Vivado is guessing routing delay. Post-route timing is measured. For a
# design this size the extra minute is free, and reporting an estimate as a
# measurement is the thing docs/PROGRESS.md and the project plan exist to stop.

set part [lindex $argv 0]
if {$part eq ""} { set part xc7a100tcsg324-1 }

set top     [lindex $argv 1]
if {$top eq ""} { set top riscv_core }
set tmr     [expr {$top eq "riscv_core_tmr"}]
set sfx     [expr {$tmr ? "_ooc_tmr" : "_ooc"}]
set sub     [expr {$tmr ? "tmr" : ""}]
set generics {}
set title    $top
if {$top eq "systolic_array"} {
    lassign [lrange $argv 2 3] rows cols
    set sfx      "_ooc_array${rows}x${cols}"
    set sub      "array${rows}x${cols}"
    set generics [list -generic ROWS=$rows -generic COLS=$cols]
    set title    "$top ${rows}x${cols}"
}
set repo    [file normalize [file join [file dirname [info script]] ..]]
set rundir  [file join $repo syn build $sub]
set reports [file join $repo docs reports]

file mkdir $rundir $reports
cd $rundir

# rtl/ is nested (core/, and tmr/, accel/, bus/, periph/ as they arrive), and
# Tcl's glob has no recursive form, so walk it. Sorted for a stable read order
# across machines.
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
read_verilog -sv $sv
read_xdc [file join $repo constr core_ooc.xdc]

synth_design -top $top -part $part -mode out_of_context {*}$generics

# A module Vivado cannot find becomes a black box with a critical warning and
# the run completes, producing a utilization report for a design with a hole in
# it -- a number that would then land in the trend table. Verilator errors on
# the same mistake; Vivado does not, so check explicitly.
set bb [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
if {[llength $bb] > 0} {
    error "black boxes in the synthesized netlist: $bb"
}

write_checkpoint -force [file join $rundir post_synth.dcp]

opt_design
place_design
route_design
write_checkpoint -force [file join $rundir post_route.dcp]

report_utilization    -file [file join $reports utilization$sfx.rpt]
report_timing_summary -file [file join $reports timing$sfx.rpt]

# --- TMR: did three copies survive? ------------------------------------------
# Each copy must still be its own hierarchy with a core's worth of cells. A
# merged design would show one populated copy and two empty or missing ones.
set copies {}
if {$tmr} {
    report_utilization -hierarchical -file [file join $reports utilization_ooc_tmr_hier.rpt]
    foreach c {u_core_a g_other[1].u_core g_other[2].u_core} {
        set n [llength [get_cells -quiet -hier -filter "IS_PRIMITIVE && NAME =~ $c/*"]]
        lappend copies $c $n
        if {$n < 500} { error "TMR copy $c has $n cells: merged or trimmed" }
    }
}

# --- derive the headline numbers -------------------------------------------
# Fmax is computed, not asserted: slack against a known period tells us what
# period the design would actually meet.  Fmax = 1000 / (period - WNS).

set clk    [get_clocks clk]
set period [get_property PERIOD $clk]
set paths  [get_timing_paths -delay_type max -max_paths 1 -nworst 1]

if {[llength $paths] == 0} {
    set wns  0.0
    set note "no timing paths found -- treat Fmax as meaningless"
} else {
    set wns  [get_property SLACK $paths]
    set note ""
}

set achieved [expr {$period - $wns}]
set fmax     [expr {$achieved > 0 ? 1000.0 / $achieved : 0.0}]

# Resource counts, and the device totals they are a fraction of. CARRY has no
# device-wide total to divide by (carry chains are a property of the slices
# already counted), so it reports a bare count -- but it is reported, because
# an adder that lands in carry logic would otherwise vanish from the table.
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
    puts $out "=== $title, out-of-context, post-route ==="
    puts $out [format "part            %s" $part]
    puts $out [format "constraint      %.3f ns (%.1f MHz)" $period [expr {1000.0/$period}]]
    puts $out [format "WNS             %.3f ns" $wns]
    puts $out [format "achieved period %.3f ns" $achieved]
    puts $out [format "Fmax            %.1f MHz" $fmax]
    if {$note ne ""} { puts $out "note            $note" }
    puts $out ""
    puts $out "Caveat: out-of-context, so HD.CLK_SRC is unset and Vivado cannot"
    puts $out "estimate clock delay or skew. Read Fmax as the core logic limit,"
    puts $out "not a board-level number -- that arrives with the Arty A7 top."
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
    if {$tmr} {
        puts $out ""
        puts $out "TMR copies (leaf cells each; DONT_TOUCH + KEEP_HIERARCHY):"
        foreach {c n} $copies { puts $out [format "  %-22s %5d" $c $n] }
    }
    puts $out ""
}
close $fh

puts "reports written to docs/reports/"
