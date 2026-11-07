// Reset synchronizer: asynchronous assertion, synchronous release.
//
// arst_i (from any domain, or none: a button, an MMCM's !LOCKED) sets
// rst_o at once, clock or no clock; rst_o falls only on a clk_i edge,
// STAGES edges after arst_i falls, so every flop in the domain leaves reset
// on the same edge and none sees the release near its clock edge.
//
// The one place in rtl/ with an asynchronous reset, and it is the point of
// the module: the domain's own flops keep the synchronous active-high
// reset (CLAUDE.md 4) and take rst_o.
//
// For a flush of several domains (cdc_async_fifo, cdc_pulse), drive every
// domain's synchronizer from the same arst_i and hold it until each clock
// has ticked at least once, so each side takes its reset before any side
// runs again.
module cdc_reset_sync #(
    parameter int unsigned STAGES = 2
) (
    input  logic clk_i,
    input  logic arst_i,
    output logic rst_o
);

  if (STAGES < 2) begin : gen_stages_check
    $error("cdc_reset_sync: STAGES must be at least 2");
  end

  (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk_i or posedge arst_i) begin
    if (arst_i) sync_q <= '1;
    else        sync_q <= {sync_q[STAGES-2:0], 1'b0};
  end

  assign rst_o = sync_q[STAGES-1];

endmodule
