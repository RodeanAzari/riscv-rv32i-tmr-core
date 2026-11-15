# Timing constraints for LibreLane run #2 (syn/asic_soc.yaml): LibreLane's
# generic constraints (clock, I/O delays, loads, derates) plus one exception.
source $::env(SCRIPTS_DIR)/base.sdc

# rst_i is asynchronous by design: it sets cdc_reset_sync's flops directly and
# is released through two synchronizer stages (rtl/top/asic_top.sv). The base
# file gives it an input delay like a synchronous input, which made the flow
# time recovery/removal against it (-1.55 ns removal at max_ss, 40 ns run,
# 2026-11-14) and insert hold buffers on it.
set_false_path -from [get_ports rst_i]
