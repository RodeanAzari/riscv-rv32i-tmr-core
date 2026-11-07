// Formal harness for cdc_async_fifo (array clock domain, Phase H slice 1).
//
// Two clocks, both free: either may rise on any step of the global clock,
// together or apart, at any ratio. Every input is free. Synchronizers are
// tb/formal/cdc_sync_meta.sv: metastable first flops.
//
// Reset: both sides start in reset, and leave it together once each has had
// SYNC_STAGES + 1 edges of its own clock in it; never again. A flush
// mid-stream is the simulation's (tb/cocotb/test_cdc_async_fifo.py).
//
// The RTL's own invariants (F1 full never lies, F2 empty never lies, F3,
// the pointer windows) are checked under it. Here, end to end, from the
// ports alone (so they hold even with those invariants removed):
//   F1  !wr_full_o means room, F2 !rd_empty_o means an entry, by the
//       harness's counts
//   F4  the pointers count exactly: the k-th accepted write, the k-th pop
//   F5  the k-th pop returns the k-th accepted write's data -- for every k
//       at once, because the tracked write is the solver's choice. That is
//       no loss, no duplication, and order.
module cdc_async_fifo_formal #(
    parameter  int unsigned WIDTH       = 4,
    parameter  int unsigned DEPTH       = 4,
    parameter  int unsigned SYNC_STAGES = 2,
    localparam int unsigned AW          = $clog2(DEPTH),
    localparam int unsigned PW          = AW + 1
) (
    input logic             wr_clk_i,
    input logic             wr_en_i,
    input logic [WIDTH-1:0] wr_data_i,
    input logic             rd_clk_i,
    input logic             rd_en_i,
    input logic             f_pick_i    // track this write
);

  logic                       wr_full_o, rd_empty_o;
  logic [PW-1:0]              wr_used_o;
  logic [WIDTH-1:0]           rd_data_o;
  logic [PW-1:0]              f_wptr, f_rptr;
  logic [DEPTH-1:0][WIDTH-1:0] f_mem;

  // ---- reset: both sides, until each has had SYNC_STAGES + 1 edges in it
  // (its own flops reset, then the other side's reset pointer through its
  // synchronizer), as cdc_reset_sync from a long enough source gives
  localparam int unsigned RST_EDGES = SYNC_STAGES + 1;
  int unsigned f_wn = 0, f_rn = 0;
  logic rst;
  assign rst = !(f_wn >= RST_EDGES && f_rn >= RST_EDGES);
  always_ff @(posedge wr_clk_i) if (rst && f_wn < RST_EDGES) f_wn <= f_wn + 1;
  always_ff @(posedge rd_clk_i) if (rst && f_rn < RST_EDGES) f_rn <= f_rn + 1;

  cdc_async_fifo #(
      .WIDTH       (WIDTH),
      .DEPTH       (DEPTH),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_fifo (
      .wr_clk_i, .wr_rst_i (rst), .wr_en_i, .wr_data_i, .wr_full_o, .wr_used_o,
      .rd_clk_i, .rd_rst_i (rst), .rd_en_i, .rd_data_o, .rd_empty_o,
      .f_wptr_o (f_wptr), .f_rptr_o (f_rptr), .f_mem_o (f_mem)
  );

  localparam logic [PW-1:0] FULL = DEPTH[PW-1:0];

  logic wr_do, rd_do;
  assign wr_do = !rst && wr_en_i && !wr_full_o;
  assign rd_do = !rst && rd_en_i && !rd_empty_o;

  // ---- F4: the harness's own counts of accepted writes and pops
  logic [PW-1:0] f_wcnt = '0, f_rcnt = '0;
  always_ff @(posedge wr_clk_i) if (wr_do) f_wcnt <= f_wcnt + 1'b1;
  always_ff @(posedge rd_clk_i) if (rd_do) f_rcnt <= f_rcnt + 1'b1;

  // ---- F5: one tracked write, the solver's choice
  logic             f_armed = 1'b0, f_done = 1'b0;
  logic [PW-1:0]    f_tag;
  logic [WIDTH-1:0] f_val;
  logic             f_live;
  assign f_live = f_armed && !f_done;
  always_ff @(posedge wr_clk_i) begin
    if (wr_do && f_pick_i && !f_armed) begin
      f_armed <= 1'b1;
      f_tag   <= f_wcnt;
      f_val   <= wr_data_i;
    end
  end
  always_ff @(posedge rd_clk_i) if (rd_do && f_live && f_rcnt == f_tag) f_done <= 1'b1;

  always_comb begin
    if (!rst) begin
      assert (f_wptr == f_wcnt);
      assert (f_rptr == f_rcnt);
      // F1, F2 by the harness's counts: never more than DEPTH held, never a
      // write accepted into a full FIFO, never a pop from an empty one
      assert (f_wcnt - f_rcnt <= FULL);
      if (!wr_full_o)  assert (f_wcnt - f_rcnt != FULL);
      if (!rd_empty_o) assert (f_wcnt != f_rcnt);
      if (f_live) begin
        // still in the FIFO, its slot untouched ...
        assert (f_tag - f_rcnt < f_wcnt - f_rcnt);
        assert (f_mem[f_tag[AW-1:0]] == f_val);
        // ... and when it is the head, the head is it
        if (!rd_empty_o && f_rcnt == f_tag) assert (rd_data_o == f_val);
      end
    end
  end

  // ---- reachability
  logic f_was_full = 1'b0;
  always_ff @(posedge wr_clk_i) if (!rst && wr_full_o) f_was_full <= 1'b1;
  always_comb begin
    if (!rst) begin
      cover (wr_full_o);
      cover (f_armed && f_done);
      cover (f_was_full && rd_empty_o && f_wcnt != '0);   // filled, then drained
      cover (f_done && f_tag == '1);   // tracked in the last slot of the second lap
    end
  end

endmodule
