# Scan.Replace (__init__.py): every flop to its scan equivalent. Fails if a
# flop is left unreplaced (it would be outside every chain, and coverage
# would silently assume it scanned).
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
read_current_odb

proc flop_counts {} {
    set plain 0
    set scan 0
    foreach inst [$::block getInsts] {
        set m [[$inst getMaster] getName]
        if { [regexp {__sdf} $m] } { incr scan } elseif { [regexp {__(df|dfx|dfr|dfs|dfb|edf)} $m] } { incr plain }
    }
    return [list $plain $scan]
}

lassign [flop_counts] p0 s0
puts "\[INFO\] before scan_replace: $p0 plain flops, $s0 scan flops"
report_design_area
log_cmd scan_replace
lassign [flop_counts] p1 s1
puts "\[INFO\] after scan_replace: $p1 plain flops, $s1 scan flops"
report_design_area
if { $p1 != 0 || $s1 != $p0 + $s0 } {
    puts stderr "\[ERROR\] scan_replace left $p1 plain flops ($s1 scan of [expr $p0 + $s0])"
    exit 1
}

write_views
