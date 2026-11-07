// Asynchronous FIFO: entries written on wr_clk_i, read on rd_clk_i, the two
// clocks unrelated (array clock domain, Phase H; docs/design-notes.md).
//
// Classic gray-pointer design. Each side keeps a pointer of AW + 1 bits (one
// more than the address, so full and empty differ), in binary for itself and
// in gray for the other side: a gray pointer changes one bit per step, so a
// synchronizer (cdc_sync, SYNC_STAGES flops) sampling it mid-change sees the
// old value or the new one, never a third. Each side therefore sees the
// other's pointer late, never wrong, and only errs on the safe side: the
// writer sees too little free space, the reader too few entries.
//
// Write side: wr_en_i with !wr_full_o writes wr_data_i. A write while full
// is ignored. wr_used_o is the occupancy as the writer sees it, an upper
// bound on the true one (entries read on the other side are counted until
// their pointer arrives): what a writer that must stop early (an
// almost-full) compares against.
//
// Read side, first-word fall-through: while !rd_empty_o, rd_data_o is the
// oldest entry; rd_en_i pops it. rd_en_i while empty is ignored. rd_data_o
// is meaningless while empty.
//
// Latency: a write is visible to the reader SYNC_STAGES read-clock edges
// after the write edge (a read likewise frees space SYNC_STAGES write-clock
// edges later).
//
// Resets: wr_rst_i and rd_rst_i are each synchronous to their own clock
// (cdc_reset_sync from one asynchronous source). They must overlap: a flush
// resets both sides, and each must take its reset (one clock edge with it
// high) before either side runs again; cdc_reset_sync from a source held for
// a few cycles of the slower clock does that. Resetting one side alone
// desynchronises the pointers.
//
// Storage is an array with an asynchronous read, distributed RAM on the
// FPGA; no reset (a reset FIFO is empty, so its contents are never read).
module cdc_async_fifo #(
    parameter  int unsigned WIDTH       = 8,
    parameter  int unsigned DEPTH       = 16,    // a power of two, at least 2
    parameter  int unsigned SYNC_STAGES = 2,
    localparam int unsigned AW          = $clog2(DEPTH),
    localparam int unsigned PW          = AW + 1
) (
    input  logic                         wr_clk_i,
    input  logic                         wr_rst_i,
    input  logic                         wr_en_i,
    input  logic [WIDTH-1:0]             wr_data_i,
    output logic                         wr_full_o,
    output logic [PW-1:0]                wr_used_o,

    input  logic                         rd_clk_i,
    input  logic                         rd_rst_i,
    input  logic                         rd_en_i,
    output logic [WIDTH-1:0]             rd_data_o,
    output logic                         rd_empty_o
`ifdef FORMAL
    ,
    // for the harness's end-to-end check (tb/formal/cdc_async_fifo_formal.sv)
    output logic [PW-1:0]                f_wptr_o,
    output logic [PW-1:0]                f_rptr_o,
    output logic [DEPTH-1:0][WIDTH-1:0]  f_mem_o
`endif
);

  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : gen_depth_check
    $error("cdc_async_fifo: DEPTH must be a power of two, at least 2");
  end

  // Assigned by name, not `return`: Yosys's parser has no `return`.
  function automatic logic [PW-1:0] bin2gray(input logic [PW-1:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic logic [PW-1:0] gray2bin(input logic [PW-1:0] g);
    for (int i = 0; i < PW; i++) gray2bin[i] = ^(g >> i);
  endfunction

  logic [WIDTH-1:0] mem [DEPTH];

  // ---- write side
  logic [PW-1:0] wbin_q, wgray_q;
  logic [PW-1:0] rgray_w;            // read pointer, synchronised to wr_clk_i
  logic [PW-1:0] wr_used;
  logic          wr_do;

  assign wr_used   = wbin_q - gray2bin(rgray_w);
  assign wr_full_o = wr_used[PW-1];  // == DEPTH: it never exceeds it
  assign wr_used_o = wr_used;
  assign wr_do     = wr_en_i && !wr_full_o;

  always_ff @(posedge wr_clk_i) begin
    if (wr_do) mem[wbin_q[AW-1:0]] <= wr_data_i;
  end

  always_ff @(posedge wr_clk_i) begin
    if (wr_rst_i) begin
      wbin_q  <= '0;
      wgray_q <= '0;
    end else if (wr_do) begin
      wbin_q  <= wbin_q + 1'b1;
      wgray_q <= bin2gray(wbin_q + 1'b1);
    end
  end

  // ---- read side
  logic [PW-1:0] rbin_q, rgray_q;
  logic [PW-1:0] wgray_r;            // write pointer, synchronised to rd_clk_i
  logic          rd_do;

  assign rd_empty_o = (rgray_q == wgray_r);
  assign rd_data_o  = mem[rbin_q[AW-1:0]];
  assign rd_do      = rd_en_i && !rd_empty_o;

  always_ff @(posedge rd_clk_i) begin
    if (rd_rst_i) begin
      rbin_q  <= '0;
      rgray_q <= '0;
    end else if (rd_do) begin
      rbin_q  <= rbin_q + 1'b1;
      rgray_q <= bin2gray(rbin_q + 1'b1);
    end
  end

  // ---- the crossings
`ifdef FORMAL
  logic [SYNC_STAGES-1:0][PW-1:0] f_rsync, f_wsync;
`endif

  cdc_sync #(
      .WIDTH  (PW),
      .STAGES (SYNC_STAGES)
  ) u_rptr_sync (
      .clk_i      (wr_clk_i),
      .rst_i      (wr_rst_i),
`ifdef FORMAL
      .f_stages_o (f_rsync),
`endif
      .d_i        (rgray_q),
      .q_o        (rgray_w)
  );

  cdc_sync #(
      .WIDTH  (PW),
      .STAGES (SYNC_STAGES)
  ) u_wptr_sync (
      .clk_i      (rd_clk_i),
      .rst_i      (rd_rst_i),
`ifdef FORMAL
      .f_stages_o (f_wsync),
`endif
      .d_i        (wgray_q),
      .q_o        (wgray_r)
  );

`ifdef FORMAL
  assign f_wptr_o = wbin_q;
  assign f_rptr_o = rbin_q;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) f_mem_o[i] = mem[i];
  end

  // Invariants, checked whenever neither side is in reset. With
  //   occ    = wbin - rbin                (the true occupancy)
  //   dw(x)  = wbin - x                   (how far x lags the writer)
  //   dr(x)  = x - rbin                   (how far x leads the reader)
  // every copy of the read pointer on its way to the writer lags the one
  // before it, and every copy of the write pointer on its way to the reader
  // likewise:
  //   dw(rbin) <= dw(rsync[0]) <= ... <= dw(rsync[last]) <= DEPTH
  //   dr(wsync[last]) <= ... <= dr(wsync[0]) <= dr(wbin) = occ <= DEPTH
  // So full and empty are never optimistic (FIFO F1, F2) and the free-running
  // views stay within one lap. The gray copies equal their binary pointers
  // (F3). Proven by tb/formal/cdc_async_fifo.sby, checked in every simulation.
  // Typed, not a size cast: Yosys has misparsed those (docs/PROGRESS.md).
  localparam logic [PW-1:0] FULL = DEPTH[PW-1:0];
  logic [PW-1:0] f_occ;
  assign f_occ = wbin_q - rbin_q;

  always_comb begin
    if (!wr_rst_i && !rd_rst_i) begin
      assert (f_occ <= FULL);
      // F1: full never lies -- room is room
      if (!wr_full_o) assert (f_occ < FULL);
      assert (wr_used >= f_occ);
      // F2: empty never lies -- an entry is an entry
      if (!rd_empty_o) assert (f_occ != '0);
      // F3
      assert (wgray_q == bin2gray(wbin_q));
      assert (rgray_q == bin2gray(rbin_q));
      // the windows
      assert (wbin_q - gray2bin(f_rsync[0]) >= f_occ);
      assert (gray2bin(f_wsync[0]) - rbin_q <= f_occ);
      for (int s = 1; s < SYNC_STAGES; s++) begin
        assert (wbin_q - gray2bin(f_rsync[s]) >= wbin_q - gray2bin(f_rsync[s-1]));
        assert (gray2bin(f_wsync[s]) - rbin_q <= gray2bin(f_wsync[s-1]) - rbin_q);
      end
      assert (wbin_q - gray2bin(f_rsync[SYNC_STAGES-1]) <= FULL);
    end
  end
`endif

endmodule
