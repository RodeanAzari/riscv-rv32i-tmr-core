# Out-of-context clocks for rtl/accel/gemm_accel.sv built with ARRAY_CDC = 1
# (make synth-accel ACCEL_CDC=1): the core's and the array's, both 100 MHz
# (the default), unrelated. The crossings are constr/accel_cdc.xdc, read
# after this one.

create_clock -name clk       -period 10.000 [get_ports clk_i]
create_clock -name clk_array -period 10.000 [get_ports clk_array_i]
