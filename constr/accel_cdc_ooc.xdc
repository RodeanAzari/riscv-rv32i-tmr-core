# Out-of-context constraints for rtl/accel/gemm_accel.sv built with
# ARRAY_CDC = 1: the core's clock and the array's, both 100 MHz (the
# default), unrelated. Read after synthesis: they name synthesized cells.
#
# Each of the two async FIFOs (u_in to the array, u_out back) is bounded as
# in constr/cdc_ooc.xdc: its gray pointers within one source period of the
# first synchronizer flop, their bits within half a destination period of
# each other; never cut by set_clock_groups, which would win over these.
# Added here, where slice 1's FIFO alone ended at a port: the storage,
# distributed RAM written on one clock and read on the other. An entry is
# read only after its write pointer has crossed (SYNC_STAGES destination
# edges after the write), so its data must reach the reader within one
# source period, as the pointer must. report_cdc cannot know that and flags
# the storage reads (CDC-1, -13, -15, -26): waived on the RAM cells alone.

create_clock -name clk       -period 10.000 [get_ports clk_i]
create_clock -name clk_array -period 10.000 [get_ports clk_array_i]

# XDC takes no loops: the two FIFOs are written out. syn/synth_ooc.tcl
# checks that every set below found its cells.

# --- u_in: written on clk, read on clk_array
set in_wsync [get_cells -hier -filter {NAME =~ *u_seq/g_cdc.u_in/u_wptr_sync/sync_q_reg[0]*}]
set in_rsync [get_cells -hier -filter {NAME =~ *u_seq/g_cdc.u_in/u_rptr_sync/sync_q_reg[0]*}]
set in_wsrc  [get_cells -of [all_fanin -startpoints_only -flat [get_pins -of $in_wsync -filter {REF_PIN_NAME == D}]]]
set in_rsrc  [get_cells -of [all_fanin -startpoints_only -flat [get_pins -of $in_rsync -filter {REF_PIN_NAME == D}]]]
set in_ram   [get_cells -hier -filter {NAME =~ *u_seq/g_cdc.u_in/mem_reg* && PRIMITIVE_GROUP == DMEM}]

set_max_delay -datapath_only -from $in_wsrc -to $in_wsync 10.000
set_max_delay -datapath_only -from $in_rsrc -to $in_rsync 10.000
set_bus_skew -from $in_wsrc -to $in_wsync 5.000
set_bus_skew -from $in_rsrc -to $in_rsync 5.000
set_max_delay -datapath_only -from $in_ram -to [get_clocks clk_array] 10.000
create_waiver -type CDC -id CDC-1 -user P1 -from [get_pins -of $in_ram -filter {REF_PIN_NAME == CLK}] \
    -description "u_in: async FIFO storage, read only after its write pointer has crossed; max delay constrained (rtl/cdc/cdc_async_fifo.sv)"
create_waiver -type CDC -id CDC-13 -user P1 -from [get_pins -of $in_ram -filter {REF_PIN_NAME == CLK}] \
    -description "u_in: async FIFO storage, read only after its write pointer has crossed; max delay constrained (rtl/cdc/cdc_async_fifo.sv)"
create_waiver -type CDC -id CDC-15 -user P1 -from [get_pins -of $in_ram -filter {REF_PIN_NAME == CLK}] \
    -description "u_in: async FIFO storage, read only after its write pointer has crossed; max delay constrained (rtl/cdc/cdc_async_fifo.sv)"
create_waiver -type CDC -id CDC-26 -user P1 -from [get_pins -of $in_ram -filter {REF_PIN_NAME == CLK}] \
    -description "u_in: async FIFO storage, read only after its write pointer has crossed; max delay constrained (rtl/cdc/cdc_async_fifo.sv)"

create_waiver -type CDC -id CDC-6 -user P1 \
    -from [get_pins -of $in_wsrc -filter {REF_PIN_NAME == C}] -to [get_pins -of $in_wsync -filter {REF_PIN_NAME == D}] \
    -description "u_in: gray-coded write pointer; max delay and bus skew constrained (rtl/cdc/cdc_async_fifo.sv)"
create_waiver -type CDC -id CDC-6 -user P1 \
    -from [get_pins -of $in_rsrc -filter {REF_PIN_NAME == C}] -to [get_pins -of $in_rsync -filter {REF_PIN_NAME == D}] \
    -description "u_in: gray-coded read pointer; max delay and bus skew constrained (rtl/cdc/cdc_async_fifo.sv)"

# --- u_out: written on clk_array, read on clk
set out_wsync [get_cells -hier -filter {NAME =~ *u_seq/g_cdc.u_out/u_wptr_sync/sync_q_reg[0]*}]
set out_rsync [get_cells -hier -filter {NAME =~ *u_seq/g_cdc.u_out/u_rptr_sync/sync_q_reg[0]*}]
set out_wsrc  [get_cells -of [all_fanin -startpoints_only -flat [get_pins -of $out_wsync -filter {REF_PIN_NAME == D}]]]
set out_rsrc  [get_cells -of [all_fanin -startpoints_only -flat [get_pins -of $out_rsync -filter {REF_PIN_NAME == D}]]]
set out_ram   [get_cells -hier -filter {NAME =~ *u_seq/g_cdc.u_out/mem_reg* && PRIMITIVE_GROUP == DMEM}]

set_max_delay -datapath_only -from $out_wsrc -to $out_wsync 10.000
set_max_delay -datapath_only -from $out_rsrc -to $out_rsync 10.000
set_bus_skew -from $out_wsrc -to $out_wsync 5.000
set_bus_skew -from $out_rsrc -to $out_rsync 5.000
set_max_delay -datapath_only -from $out_ram -to [get_clocks clk] 10.000
create_waiver -type CDC -id CDC-15 -user P1 -from [get_pins -of $out_ram -filter {REF_PIN_NAME == CLK}] \
    -description "u_out: async FIFO storage, read only after its write pointer has crossed; max delay constrained (rtl/cdc/cdc_async_fifo.sv)"

create_waiver -type CDC -id CDC-6 -user P1 \
    -from [get_pins -of $out_wsrc -filter {REF_PIN_NAME == C}] -to [get_pins -of $out_wsync -filter {REF_PIN_NAME == D}] \
    -description "u_out: gray-coded write pointer; max delay and bus skew constrained (rtl/cdc/cdc_async_fifo.sv)"
create_waiver -type CDC -id CDC-6 -user P1 \
    -from [get_pins -of $out_rsrc -filter {REF_PIN_NAME == C}] -to [get_pins -of $out_rsync -filter {REF_PIN_NAME == D}] \
    -description "u_out: gray-coded read pointer; max delay and bus skew constrained (rtl/cdc/cdc_async_fifo.sv)"

# The resets: rst_i asserts the array side's synchronizer at once, and that
# reset asserts the core side's (gemm_accel.sv). Asynchronous assertion into
# a reset synchronizer has no timing to meet; the release is synchronous in
# each domain.
set_false_path -to [get_pins -hier -filter {NAME =~ *g_rst_cdc.u_rst_a/sync_q_reg*/PRE}]
set_false_path -to [get_pins -hier -filter {NAME =~ *g_rst_cdc.u_rst_c/sync_q_reg*/PRE}]
# report_cdc files rst_i (an input port, no clock out of context) into the
# first reset synchronizer under CDC-26; it is the asynchronous assertion
# above.
create_waiver -type CDC -id CDC-26 -user P1 -from [get_ports rst_i] \
    -to [get_pins -hier -filter {NAME =~ *g_rst_cdc.u_rst_a/sync_q_reg*/PRE}] \
    -description "asynchronous reset assertion into cdc_reset_sync (rtl/accel/gemm_accel.sv)"
