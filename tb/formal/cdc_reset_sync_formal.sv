// Formal harness for cdc_reset_sync (array clock domain, Phase H slice 1).
// A free clock and a free asynchronous reset; the first step is in reset.
//   R1  arst_i high: rst_o high, on the same step, clock or no clock
//   R2  rst_o falls only on a rising edge of clk_i
//   R3  rst_o falls only once STAGES rising edges have passed with arst_i low
module cdc_reset_sync_formal #(
    parameter int unsigned STAGES = 2
) (
    input logic clk_i,
    input logic arst_i
);

  logic rst_o;

  cdc_reset_sync #(
      .STAGES (STAGES)
  ) u_rs (
      .clk_i, .arst_i, .rst_o
  );

  logic        f_first = 1'b1;
  logic        clk_last, rst_last;
  logic        edge_now;
  int unsigned f_n;     // rising edges since arst_i was last high, saturating
  assign edge_now = clk_i && !clk_last;

  always @($global_clock) begin
    f_first  <= 1'b0;
    clk_last <= clk_i;
    rst_last <= rst_o;
    if (arst_i)                      f_n <= 0;
    else if (edge_now && f_n < STAGES) f_n <= f_n + 1;
  end

  always_comb begin
    if (f_first) assume (arst_i);
    if (arst_i) assert (rst_o);                                     // R1
    if (!f_first && rst_last && !rst_o) begin
      assert (edge_now);                                            // R2
      assert (f_n + 1 >= STAGES);                                   // R3 (this edge counts)
    end
    if (!f_first) cover (rst_last && !rst_o);
    if (!f_first) cover (!rst_last && rst_o && !clk_i);             // asserted with no edge
  end

endmodule
