// Formal harness: the TMR voter (docs/buildplan.md 5.7, "formally verify the
// voter: any two agreeing inputs produce that output").
//
// The voter is combinational and all three inputs are free, so each assertion
// is checked for every possible combination of 3 x W bits -- at W = 32, the
// width the TMR core votes on most -- not a sample of them.
module tmr_voter_formal #(
    parameter int unsigned W = 32
) (
    input logic [W-1:0] a_i,
    input logic [W-1:0] b_i,
    input logic [W-1:0] c_i
);

  logic [W-1:0] y;
  logic         mismatch;
  logic [2:0]   disagree;

  tmr_voter #(.W(W)) u_dut (
      .a_i        (a_i),
      .b_i        (b_i),
      .c_i        (c_i),
      .y_o        (y),
      .mismatch_o (mismatch),
      .disagree_o (disagree)
  );

  always_comb begin
    // V1: any two agreeing inputs produce that output.
    if (a_i == b_i) assert (y == a_i);
    if (a_i == c_i) assert (y == a_i);
    if (b_i == c_i) assert (y == b_i);
    // V2: mismatch is exactly "not all three equal".
    assert (mismatch == !(a_i == b_i && b_i == c_i));
    // V3: with two in agreement, the flags name exactly the odd one out.
    if (a_i == b_i) assert (disagree == {c_i != a_i, 1'b0, 1'b0});
    if (a_i == c_i) assert (disagree == {1'b0, b_i != a_i, 1'b0});
    if (b_i == c_i) assert (disagree == {1'b0, 1'b0, a_i != b_i});
    // V4: every output bit is some input's bit -- never invented.
    assert (((y ^ a_i) & (y ^ b_i) & (y ^ c_i)) == '0);
  end

  // Reachability: each case the assertions guard must arise.
  always_comb begin
    cover (a_i == b_i && b_i == c_i);                   // all agree
    cover (a_i == b_i && c_i != a_i && disagree == 3'b100);  // C outvoted
    cover (a_i == c_i && b_i != a_i && disagree == 3'b010);  // B outvoted
    cover (b_i == c_i && a_i != b_i && disagree == 3'b001);  // A outvoted
    cover (a_i != b_i && a_i != c_i && b_i != c_i);     // all differ
  end

endmodule
