// Lint stand-in for the Xilinx MMCME2_BASE primitive, so `make lint` can
// check rtl/top/arty_a7_top.sv. Only the ports and parameters that top uses.
// Never read by Vivado (it has the real primitive) and not a timing model:
// CLKOUT0 is simply CLKIN1, and LOCKED is always high.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module MMCME2_BASE #(
    parameter real    CLKIN1_PERIOD    = 10.0,
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter real    CLKFBOUT_MULT_F  = 5.0,
    parameter real    CLKOUT0_DIVIDE_F = 1.0
) (
    input  logic CLKIN1,
    input  logic CLKFBIN,
    output logic CLKFBOUT,
    output logic CLKOUT0,
    output logic LOCKED,
    input  logic PWRDWN,
    input  logic RST
);
  assign CLKFBOUT = CLKIN1;
  assign CLKOUT0  = CLKIN1;
  assign LOCKED   = 1'b1;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
