# Timing constraints for LibreLane run #2 (syn/asic_soc.yaml): LibreLane's
# generic constraints (clock, I/O delays, loads, derates) plus one exception.
source $::env(SCRIPTS_DIR)/base.sdc

# rst_i is asynchronous by design: it sets cdc_reset_sync's flops directly and
# is released through two synchronizer stages (rtl/top/asic_top.sv). The base
# file gives it an input delay like a synchronous input, which made the flow
# time recovery/removal against it (-1.55 ns removal at max_ss, 40 ns run,
# 2026-11-14) and insert hold buffers on it.
set_false_path -from [get_ports rst_i]

# uart_rx_i is asynchronous too: the host's USB-UART bridge drives it with no
# relation to clk_i, and its one sink is the first flop of uart_rx's two-flop
# synchronizer (rtl/periph/uart_rx.sv). Timed as a synchronous input it failed
# hold by -0.92 ns at max_ss (50 ns run, 2026-11-15).
set_false_path -from [get_ports uart_rx_i]

# scan_in_<k> (make asic SCAN=1 only; absent otherwise): the tester drives
# them at mid-cycle, not 20% after the edge. With the base file's 10 ns they
# failed hold at the ss corners (-1.82 ns at max_ss, 23 paths, all scan_in,
# 2026-11-23): the clock reaches the first scan flop about 13.6 ns after the
# edge. Test requirement, stated in the README: drive scan_in 25 ns after clk_i.
set scan_in_ports [get_ports -quiet scan_in_*]
if { [llength $scan_in_ports] } {
    set_input_delay [expr $::env(CLOCK_PERIOD) / 2.0] -clock $clocks $scan_in_ports
}
