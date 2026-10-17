// Lint stand-in for the Xilinx BUFG primitive (global clock buffer), so
// `make lint` can check rtl/top/arty_a7_top.sv. Never read by Vivado.
module BUFG (
    input  logic I,
    output logic O
);
  assign O = I;
endmodule
