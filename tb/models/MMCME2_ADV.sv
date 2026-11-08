// Lint stand-in for the Xilinx MMCME2_ADV primitive, so `make lint` can
// check rtl/top/arty_a7_top.sv with ARRAY_CDC = 1. Only the ports and
// parameters that top uses. Never read by Vivado (it has the real
// primitive) and not a model: CLKOUT0 is CLKIN1, LOCKED is !RST, and the
// DRP answers every access the next DCLK with 0. The behaviour tests use
// sw/model/mmcm_drp.py and AMD's own model (make aclk-check).
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module MMCME2_ADV #(
    parameter real    CLKIN1_PERIOD    = 10.0,
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter real    CLKFBOUT_MULT_F  = 5.0,
    parameter real    CLKOUT0_DIVIDE_F = 1.0
) (
    input  logic        CLKIN1,
    input  logic        CLKIN2,
    input  logic        CLKINSEL,
    input  logic        CLKFBIN,
    output logic        CLKFBOUT,
    output logic        CLKOUT0,
    output logic        LOCKED,
    input  logic        DCLK,
    input  logic [6:0]  DADDR,
    input  logic        DEN,
    input  logic        DWE,
    input  logic [15:0] DI,
    output logic [15:0] DO,
    output logic        DRDY,
    input  logic        PSCLK,
    input  logic        PSEN,
    input  logic        PSINCDEC,
    input  logic        PWRDWN,
    input  logic        RST
);
  assign CLKFBOUT = CLKIN1;
  assign CLKOUT0  = CLKIN1;
  assign LOCKED   = !RST;
  assign DO       = '0;
  always_ff @(posedge DCLK) DRDY <= DEN;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
