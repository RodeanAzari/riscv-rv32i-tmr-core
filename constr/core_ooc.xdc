# Out-of-context timing constraint for riscv_core.
#
# 10 ns because the Arty A7 carries a 100 MHz oscillator. Constraining at the
# board's real frequency makes the slack number answer a question that matters:
# does this close timing on the hardware we own?
#
# There are no pin constraints here on purpose. The core is synthesized
# out-of-context, so its ports are internal signals rather than package pins.
# Pin assignments arrive with constr/arty_a7.xdc when a board-level top exists.

# The clock OBJECT stays named clk even though the port is clk_i: syn/synth_ooc.tcl
# and every committed report identify it by that name, and a timing object should
# not be renamed every time RTL port naming conventions shift.
create_clock -name clk -period 10.000 [get_ports clk_i]
