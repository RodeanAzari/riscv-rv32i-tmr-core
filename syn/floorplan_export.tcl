# Export the placement and routing of the routed board design for
# scripts/floorplan.py, which draws it as a zoomable SVG.
#
#   vivado -mode batch -source syn/floorplan_export.tcl -tclargs <dcp> <outdir>
#
# Writes four tab-separated files: the device's tiles (name, type, grid
# position), clock regions, every placed leaf cell (site, BEL, tile) and every
# routed signal net (driver cell, ROUTE string), plus the cells and nets of
# the worst setup path. Grid positions are Vivado's tile grid: a CLB and its
# interconnect tile are separate columns, rows count down from the top.

set dcp    [lindex $argv 0]
set outdir [lindex $argv 1]
if {![file exists $dcp]} { error "$dcp not found -- run make impl first" }
file mkdir $outdir
open_checkpoint $dcp

proc dump {path header rows} {
    set f [open $path w]
    puts $f [join $header \t]
    foreach r $rows { puts $f [join $r \t] }
    close $f
}

# Tiles: one get_property per column of values, not per tile.
set tiles [get_tiles]
set rows {}
foreach n [get_property NAME $tiles] t [get_property TYPE $tiles] \
        x [get_property GRID_POINT_X $tiles] y [get_property GRID_POINT_Y $tiles] {
    lappend rows [list $n $t $x $y]
}
dump [file join $outdir tiles.tsv] {name type x y} $rows

set rows {}
foreach cr [get_clock_regions] {
    lappend rows [list $cr [get_property TOP_LEFT_TILE $cr] [get_property BOTTOM_RIGHT_TILE $cr]]
}
dump [file join $outdir clock_regions.tsv] {name top_left bottom_right} $rows

# Placed leaf cells, with the tile of their site.
set cells [get_cells -hier -filter {IS_PRIMITIVE && STATUS != UNPLACED && LOC != ""}]
array set site_tile {}
foreach s [lsort -unique [get_property LOC $cells]] {
    set site_tile($s) [get_tiles -of_objects [get_sites $s]]
}
set rows {}
foreach n [get_property NAME $cells] loc [get_property LOC $cells] \
        bel [get_property BEL $cells] ref [get_property REF_NAME $cells] {
    lappend rows [list $n $ref $loc $bel $site_tile($loc)]
}
dump [file join $outdir cells.tsv] {name ref site bel tile} $rows

# Routed signal nets (not the clock or power), named once per physical net,
# each as its routing nodes. A node is one physical wire and spans tiles; it
# is written as the tiles where it meets the rest of the route -- a switch
# (PIP) of this net, or a placed cell's tile -- so drawing those in order
# traces the wire. ROUTE itself names wires without their tiles.
set nets [get_nets -hier -top_net_of_hierarchical_group \
              -filter {ROUTE_STATUS == ROUTED && TYPE == SIGNAL}]
set rows {}
foreach net $nets {
    set drv [get_cells -quiet -of_objects \
                 [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]]
    array unset hit
    foreach p [get_pips -of_objects $net] { set hit([lindex [split $p /] 0]) 1 }
    foreach c [get_cells -quiet -of_objects $net] {
        set loc [get_property LOC $c]
        if {$loc ne ""} { set hit($site_tile($loc)) 1 }
    }
    set segs {}
    foreach node [get_nodes -of_objects $net] {
        set ts {}
        foreach w [get_wires -of_objects $node] {
            set t [lindex [split $w /] 0]
            if {[info exists hit($t)] && [lsearch -exact $ts $t] < 0} { lappend ts $t }
        }
        if {[llength $ts] > 1} { lappend segs [join $ts ,] }
    }
    lappend rows [list $net [lindex $drv 0] [join $segs " "]]
}
dump [file join $outdir nets.tsv] {name driver segments} $rows

set worst [get_timing_paths -max_paths 1 -nworst 1 -setup]
set rows [list [list slack [get_property SLACK $worst]]]
foreach c [get_cells -of_objects $worst] { lappend rows [list cell $c] }
foreach n [get_nets -top_net_of_hierarchical_group -of_objects $worst] { lappend rows [list net $n] }
dump [file join $outdir worst_path.tsv] {kind name} $rows

puts "floorplan export: [llength $tiles] tiles, [llength $cells] cells, [llength $nets] nets -> $outdir"
