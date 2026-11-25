// Port-only stand-ins for the two OpenRAM macros, for the gate-level scan
// shift test of the SoC (make asic SOC=1 SCAN=1, scripts/scan_shift_tb.py).
// The PDK's behavioural models do not elaborate in Icarus (they index `mem`
// before declaring it); make sram-check simulates them in Verilator instead.
// Shifting uses only the scan path (SCD), so the outputs are X: if an SRAM
// output reached a scan-out, the shift check would see X and fail.

module sky130_sram_2kbyte_1rw1r_32x512_8 (
  input         clk0,
  input         csb0,
  input         web0,
  input  [3:0]  wmask0,
  input  [8:0]  addr0,
  input  [31:0] din0,
  output [31:0] dout0,
  input         clk1,
  input         csb1,
  input  [8:0]  addr1,
  output [31:0] dout1
);
  assign dout0 = 32'bx;
  assign dout1 = 32'bx;
endmodule

module sky130_sram_1kbyte_1rw1r_32x256_8 (
  input         clk0,
  input         csb0,
  input         web0,
  input  [3:0]  wmask0,
  input  [7:0]  addr0,
  input  [31:0] din0,
  output [31:0] dout0,
  input         clk1,
  input         csb1,
  input  [7:0]  addr1,
  output [31:0] dout1
);
  assign dout0 = 32'bx;
  assign dout1 = 32'bx;
endmodule
