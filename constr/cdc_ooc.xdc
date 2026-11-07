# Out-of-context constraints for rtl/cdc/cdc_async_fifo.sv on its own: two
# clocks, both 100 MHz (the core's and the array's default), unrelated.
#
# The crossings are bounded, not cut. Each gray pointer leaves its flops and
# reaches the first synchronizer flop on the other side within one source
# period (set_max_delay -datapath_only), and its bits within half a
# destination period of each other (set_bus_skew): what keeps "one bit
# changes per source edge" true at the far end, and what the formal model
# (tb/formal/cdc_sync_meta.sv) assumes. set_clock_groups -asynchronous would
# cut these paths instead, and it wins over set_max_delay, so it is not used.
#
# The board build (Phase H, ARRAY_CDC = 1) takes the same constraints.

create_clock -name wr_clk -period 10.000 [get_ports wr_clk_i]
create_clock -name rd_clk -period 10.000 [get_ports rd_clk_i]

# Sources by fanin, not by name: Vivado merges a gray pointer's top bit with
# the binary pointer's (they are equal), so a name filter misses that bit
# and leaves it unconstrained (seen in report_cdc, 2026-11-07).
set wsync [get_cells -hier -filter {NAME =~ *u_wptr_sync/sync_q_reg[0]*}]
set rsync [get_cells -hier -filter {NAME =~ *u_rptr_sync/sync_q_reg[0]*}]
set wsrc  [get_cells -of [all_fanin -startpoints_only -flat [get_pins -of $wsync -filter {REF_PIN_NAME == D}]]]
set rsrc  [get_cells -of [all_fanin -startpoints_only -flat [get_pins -of $rsync -filter {REF_PIN_NAME == D}]]]

set_max_delay -datapath_only -from $wsrc -to $wsync 10.000
set_max_delay -datapath_only -from $rsrc -to $rsync 10.000
set_bus_skew -from $wsrc -to $wsync 5.000
set_bus_skew -from $rsrc -to $rsync 5.000

# report_cdc cannot know a bus is gray-coded, so it warns on every multi-bit
# synchronizer (CDC-6). These two are, and are bounded above.
create_waiver -type CDC -id CDC-6 -user P1 \
    -from [get_pins -of $wsrc -filter {REF_PIN_NAME == C}] -to [get_pins -of $wsync -filter {REF_PIN_NAME == D}] \
    -description "gray-coded write pointer; max delay and bus skew constrained (rtl/cdc/cdc_async_fifo.sv)"
create_waiver -type CDC -id CDC-6 -user P1 \
    -from [get_pins -of $rsrc -filter {REF_PIN_NAME == C}] -to [get_pins -of $rsync -filter {REF_PIN_NAME == D}] \
    -description "gray-coded read pointer; max delay and bus skew constrained (rtl/cdc/cdc_async_fifo.sv)"
