// 2-of-3 majority voter for triple modular redundancy (CLAUDE.md 5.7).
//
// Bitwise majority: each output bit is the value at least two inputs agree
// on. So whenever two whole inputs agree, the output is that value, whatever
// the third holds -- the property docs/buildplan.md 5.7 asks to prove, and
// tb/formal/tmr_voter_formal.sv does. If all three differ, each bit still
// takes its own majority; no copy is trusted wholesale.
//
// mismatch_o: the three inputs are not all equal. disagree_o[i]: input i
// differs from the output -- which copy is the odd one out, for the
// mismatch counter and the fault-injection statistics. Purely
// combinational: a voter adds one LUT level, no state.
module tmr_voter #(
    parameter int unsigned W = 32
) (
    input  logic [W-1:0] a_i,
    input  logic [W-1:0] b_i,
    input  logic [W-1:0] c_i,
    output logic [W-1:0] y_o,
    output logic         mismatch_o,
    output logic [2:0]   disagree_o
);

  assign y_o        = (a_i & b_i) | (a_i & c_i) | (b_i & c_i);
  assign mismatch_o = (a_i != b_i) || (a_i != c_i);
  assign disagree_o = {c_i != y_o, b_i != y_o, a_i != y_o};

endmodule
