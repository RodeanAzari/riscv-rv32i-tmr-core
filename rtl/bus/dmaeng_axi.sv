// DMA engine transport: an AXI4 master that carries out the descriptor
// sequencer's commands (Phase G, buildplan 6.3). Everything AXI about the
// DMA is here; dmaeng_desc.sv never sees a bus signal, so a different
// transport (DMA-Engine 14: a PCIe bridge) replaces only this file.
//
// Commands (cmd_op_i), one at a time, each ending with a one-cycle done_o:
//   OP_READ   read cmd_len_i bytes at cmd_src_i (word aligned, inside one
//             4 KiB page: a descriptor); every beat goes out on rd_valid_o
//   OP_WRITE  write the word cmd_wdata_i at cmd_src_i (status, flags)
//   OP_COPY   copy cmd_len_i bytes from cmd_src_i to cmd_dst_i, any byte
//             alignment, as DMA-Engine's QEMU device does
// done_err_o: some response was SLVERR or DECERR.
//
// A copy goes in chunks: a read burst into the buffer, then a write burst
// out of it. A chunk never crosses a 4 KiB boundary on either side (an AXI4
// burst may not; DMA-Engine rule 4) and fits the buffer on both sides. Bytes
// are realigned on the way out: write beat k, lane j takes the byte at
// position k*L + j + (src - dst) mod L of the read stream (L bytes a beat),
// a funnel shift over two buffered words; byte strobes cover exactly the
// chunk. Chunks run in address order, so a copy whose destination overlaps
// its source by more than a chunk ahead is not a memmove (the model's is).
//
// On a read error the chunk is not written and the copy stops; on a write
// error the copy stops after that chunk. abort_i (CTRL.RESET) lets the
// burst in flight finish, as AXI requires, then ends the command.
//
// One transaction in flight; AWVALID and WVALID rise together and neither
// waits for the other's READY. AXI IDs, cache, prot and lock are left to the
// interconnect.

module dmaeng_axi
  import dmaeng_pkg::*;
#(
  parameter  int ADDR_W    = 32,
  parameter  int DATA_W    = 32,
  parameter  int BUF_WORDS = 16,        // buffer, and longest burst, in beats
  localparam int STRB_W    = DATA_W / 8,
  localparam int LANE_W    = $clog2(STRB_W),
  localparam int LEN_W     = $clog2(MAX_XFER_DEFAULT + 1),
  localparam int WORD_W    = 32         // OP_WRITE's word: a register's width
) (
  input  logic              clk_i,
  input  logic              rst_i,

  // commands from the sequencer
  input  logic              cmd_valid_i,
  output logic              cmd_ready_o,
  input  logic [1:0]        cmd_op_i,
  input  logic [ADDR_W-1:0] cmd_src_i,
  input  logic [ADDR_W-1:0] cmd_dst_i,
  input  logic [LEN_W-1:0]  cmd_len_i,
  input  logic [WORD_W-1:0] cmd_wdata_i,
  input  logic              abort_i,
  output logic              rd_valid_o,
  output logic [DATA_W-1:0] rd_data_o,
  output logic              done_o,
  output logic              done_err_o,

  // AXI4 master
  output logic [ADDR_W-1:0] m_araddr_o,
  output logic [7:0]        m_arlen_o,
  output logic [2:0]        m_arsize_o,
  output logic [1:0]        m_arburst_o,
  output logic              m_arvalid_o,
  input  logic              m_arready_i,
  input  logic [DATA_W-1:0] m_rdata_i,
  input  logic [1:0]        m_rresp_i,
  input  logic              m_rlast_i,
  input  logic              m_rvalid_i,
  output logic              m_rready_o,
  output logic [ADDR_W-1:0] m_awaddr_o,
  output logic [7:0]        m_awlen_o,
  output logic [2:0]        m_awsize_o,
  output logic [1:0]        m_awburst_o,
  output logic              m_awvalid_o,
  input  logic              m_awready_i,
  output logic [DATA_W-1:0] m_wdata_o,
  output logic [STRB_W-1:0] m_wstrb_o,
  output logic              m_wlast_o,
  output logic              m_wvalid_o,
  input  logic              m_wready_i,
  input  logic [1:0]        m_bresp_i,
  input  logic              m_bvalid_i,
  output logic              m_bready_o
);

  localparam logic [1:0] OP_READ  = 2'd0;
  localparam logic [1:0] OP_WRITE = 2'd1;
  localparam logic [1:0] OP_COPY  = 2'd2;

  // OP_WRITE puts one register-width word on the bus as one beat; the
  // descriptor sequencer also takes its fetch a word a beat.
  if (DATA_W != WORD_W) begin : g_width_check
    $error("dmaeng_axi: only DATA_W = 32 is built so far");
  end

  localparam int        PAGE_BYTES = 4096;   // AXI4: no burst crosses 4 KiB
  localparam int        PAGE_W     = $clog2(PAGE_BYTES);
  localparam int        BUF_BYTES  = BUF_WORDS * STRB_W;
  localparam int        IDX_W      = $clog2(BUF_WORDS);
  localparam int        CHUNK_W    = $clog2(BUF_BYTES + 1);
  localparam int        BEAT_W     = $clog2(BUF_WORDS + 1);
  localparam logic [1:0] BURST_INCR = 2'b01;

  typedef enum logic [2:0] {
    S_IDLE, S_CALC, S_AR, S_R, S_W, S_B, S_DONE
  } state_t;
  state_t state_q;

  logic [1:0]        op_q;
  logic [ADDR_W-1:0] src_q, dst_q;
  logic [LEN_W-1:0]  rem_q;          // bytes still to copy
  logic [WORD_W-1:0] wdata_q;
  logic [CHUNK_W-1:0] n_q;           // this chunk's bytes
  logic [BEAT_W-1:0] rbeats, wbeats;   // from n_q and the lane offsets
  logic [BEAT_W-1:0] beat_q;         // R beats taken / W beats sent
  logic              aw_done_q;
  logic              err_q;

  logic [DATA_W-1:0] buf_q [BUF_WORDS];

  // --- chunk size ------------------------------------------------------------
  // min(rest of the copy, what fits the buffer on both sides, what is left
  // of the 4 KiB page on both sides)
  logic [LANE_W-1:0]   sa, da;            // lane offsets of src and dst
  logic [PAGE_W:0]     src_page_left, dst_page_left;
  logic [CHUNK_W-1:0]  buf_left;
  logic [LEN_W-1:0]    n_calc;
  assign sa = src_q[LANE_W-1:0];
  assign da = dst_q[LANE_W-1:0];
  assign src_page_left = (PAGE_W + 1)'(PAGE_BYTES) - {1'b0, src_q[PAGE_W-1:0]};
  assign dst_page_left = (PAGE_W + 1)'(PAGE_BYTES) - {1'b0, dst_q[PAGE_W-1:0]};
  assign buf_left = CHUNK_W'(BUF_BYTES) - CHUNK_W'(sa > da ? sa : da);

  always_comb begin
    n_calc = rem_q;
    if (LEN_W'(buf_left) < n_calc)      n_calc = LEN_W'(buf_left);
    if (LEN_W'(src_page_left) < n_calc) n_calc = LEN_W'(src_page_left);
    if (LEN_W'(dst_page_left) < n_calc) n_calc = LEN_W'(dst_page_left);
  end

  // beats a chunk of n_q bytes covers, from a lane offset. Derived from the
  // registered chunk size rather than registered themselves: the size's
  // chain of minimums and this adder in one cycle missed 100 MHz. A read or
  // a word write sets n_q at the command (aligned, so the same formula).
  logic [CHUNK_W:0] rspan, wspan;
  assign rspan  = (CHUNK_W + 1)'(n_q) + (CHUNK_W + 1)'(sa) + (CHUNK_W + 1)'(STRB_W - 1);
  assign wspan  = (CHUNK_W + 1)'(n_q) + (CHUNK_W + 1)'(da) + (CHUNK_W + 1)'(STRB_W - 1);
  assign rbeats = BEAT_W'(rspan >> LANE_W);
  assign wbeats = BEAT_W'(wspan >> LANE_W);

  // --- write data: realign the buffered read stream --------------------------
  // delta = (src - dst) mod L. For sa >= da, beat k takes words k and k+1;
  // for sa < da, words k-1 and k. Indices past the burst read stale words,
  // but only into lanes the strobes leave off.
  logic [IDX_W-1:0]    lo_idx, hi_idx;
  logic [LANE_W-1:0]   shift;
  logic [2*DATA_W-1:0] pair;
  logic [DATA_W-1:0]   copy_wdata;
  logic [STRB_W-1:0]   copy_wstrb;
  always_comb begin
    lo_idx = (sa >= da) ? IDX_W'(beat_q) : IDX_W'(beat_q) - 1'b1;
    hi_idx = lo_idx + 1'b1;
    shift  = sa - da;                       // mod L, by width
    pair   = {buf_q[hi_idx], buf_q[lo_idx]} >> {shift, 3'b000};
    copy_wdata = pair[DATA_W-1:0];
    for (int j = 0; j < STRB_W; j++) begin
      // byte position in the dst-aligned window: valid inside [da, da + n)
      copy_wstrb[j] = ({beat_q, LANE_W'(j)} >= (BEAT_W + LANE_W)'(da)) &&
                      ({beat_q, LANE_W'(j)} < (BEAT_W + LANE_W)'(da) + (BEAT_W + LANE_W)'(n_q));
    end
  end

  // --- AXI signals -------------------------------------------------------------
  logic is_write;
  assign is_write = op_q == OP_WRITE;

  assign m_araddr_o  = {src_q[ADDR_W-1:LANE_W], {LANE_W{1'b0}}};
  assign m_arlen_o   = 8'(rbeats - 1'b1);
  assign m_arsize_o  = 3'(LANE_W);
  assign m_arburst_o = BURST_INCR;
  assign m_arvalid_o = state_q == S_AR;
  assign m_rready_o  = state_q == S_R;

  assign m_awaddr_o  = is_write ? src_q : {dst_q[ADDR_W-1:LANE_W], {LANE_W{1'b0}}};
  assign m_awlen_o   = is_write ? 8'd0 : 8'(wbeats - 1'b1);
  assign m_awsize_o  = 3'(LANE_W);
  assign m_awburst_o = BURST_INCR;
  assign m_awvalid_o = state_q == S_W && !aw_done_q;
  assign m_wvalid_o  = state_q == S_W && beat_q != wbeats;
  assign m_wdata_o   = is_write ? wdata_q : copy_wdata;
  assign m_wstrb_o   = is_write ? '1 : copy_wstrb;
  assign m_wlast_o   = beat_q == wbeats - 1'b1;
  assign m_bready_o  = state_q == S_B;

  assign cmd_ready_o = state_q == S_IDLE;
  assign rd_valid_o  = state_q == S_R && m_rvalid_i && op_q == OP_READ;
  assign rd_data_o   = m_rdata_i;
  assign done_o      = state_q == S_DONE;
  assign done_err_o  = err_q;

  // RESP[1] is the error bit (SLVERR, DECERR alike); the funnel's upper word
  // is what the shift leaves behind. Named unused_* so lint knows.
  logic unused_bits;
  assign unused_bits = ^{m_rresp_i[0], m_bresp_i[0], pair[2*DATA_W-1:DATA_W]};

  logic [LEN_W-1:0] rem_next;
  assign rem_next = rem_q - LEN_W'(n_q);

  always_ff @(posedge clk_i) begin
    if (m_rvalid_i && m_rready_o) begin
      buf_q[IDX_W'(beat_q)] <= m_rdata_i;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q   <= S_IDLE;
      op_q      <= OP_READ;
      src_q     <= '0;
      dst_q     <= '0;
      rem_q     <= '0;
      wdata_q   <= '0;
      n_q       <= '0;
      beat_q    <= '0;
      aw_done_q <= 1'b0;
      err_q     <= 1'b0;
    end else begin
      unique case (state_q)
        S_IDLE: if (cmd_valid_i) begin
          op_q    <= cmd_op_i;
          src_q   <= cmd_src_i;
          // a word write's address is its src; held in dst_q too, so the
          // write-side lane offset is 0
          dst_q   <= cmd_op_i == OP_WRITE ? cmd_src_i : cmd_dst_i;
          rem_q   <= cmd_len_i;
          wdata_q <= cmd_wdata_i;
          err_q   <= 1'b0;
          beat_q  <= '0;
          aw_done_q <= 1'b0;
          unique case (cmd_op_i)
            OP_READ: begin
              n_q      <= CHUNK_W'(cmd_len_i);
              state_q  <= S_AR;
            end
            OP_WRITE: begin
              n_q      <= CHUNK_W'(WORD_W / 8);
              state_q  <= S_W;
            end
            default: state_q <= S_CALC;
          endcase
        end
        S_CALC: begin
          n_q      <= CHUNK_W'(n_calc);
          beat_q   <= '0;
          state_q  <= S_AR;
        end
        S_AR: if (m_arready_i) state_q <= S_R;
        S_R: if (m_rvalid_i) begin
          beat_q <= beat_q + 1'b1;
          if (m_rresp_i[1]) err_q <= 1'b1;
          if (m_rlast_i) begin
            beat_q    <= '0;
            aw_done_q <= 1'b0;
            // a failed read is not written; an abort writes nothing more
            state_q <= (op_q == OP_READ || m_rresp_i[1] || err_q || abort_i)
                       ? S_DONE : S_W;
          end
        end
        S_W: begin
          if (m_awvalid_o && m_awready_i) aw_done_q <= 1'b1;
          if (m_wvalid_o && m_wready_i) beat_q <= beat_q + 1'b1;
          if ((aw_done_q || m_awready_i) &&
              (beat_q == wbeats || (m_wvalid_o && m_wready_i && m_wlast_o)))
            state_q <= S_B;
        end
        S_B: if (m_bvalid_i) begin
          if (m_bresp_i[1] || op_q != OP_COPY || rem_next == '0 || abort_i) begin
            err_q   <= err_q || m_bresp_i[1];
            state_q <= S_DONE;
          end else begin
            src_q   <= src_q + ADDR_W'(n_q);
            dst_q   <= dst_q + ADDR_W'(n_q);
            rem_q   <= rem_next;
            state_q <= S_CALC;
          end
        end
        S_DONE: state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
