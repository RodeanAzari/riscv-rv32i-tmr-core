// The GEMM accelerator's sequencer and datapath (Phase G): runs one whole
// job, C = A @ W, from the accelerator's buffers through the systolic array.
// Golden model: Accel.run() and job_cycles() in sw/model/accel_model.py,
// whose docstring has the buffer layouts.
//
// start_i takes M, K, N. Three cycles check the shape (no dimension 0, each
// matrix within its buffer): products are formed one cycle and compared the
// next, off the hot path. A refused shape ends there with error_o.
// Otherwise the tiles run N outer, K inner, one at a time:
//   LOAD    ROWS cycles: W's rows k0 + ROWS - 1 down to k0 shift into the
//           array's shadow weights (rows past K and columns past N as 0)
//   SWAP    one cycle: the shadows become the active weights
//   STREAM  M cycles: A's rows, one a cycle
//   DRAIN   until the last row's sum is in C (LATENCY + 2 cycles)
// No overlap between tiles: the next load waits for the drain, so a row's
// read-modify-write of C never meets another's. Overlapping them is the
// first lever on utilization, and a measured change of its own.
//
// Every buffer read is issued one cycle ahead: the control word (valid,
// swap, shift, the weight mask) is registered alongside, so it reaches the
// array with the data. Behind the array a row's sums are registered while
// its old C line is read, then written back, plus the old line unless this
// is the first tile along K.
//
// ARRAY_CDC = 1 (Phase H, array clock domain): the array runs on
// clk_array_i, everything else here stays on clk_i. Golden model:
// stream_job() in sw/model/accel_cdc_model.py, CYCLES included. The entries
// above (each shift, the swap, each row of A, with their data) go through an
// async FIFO instead of straight in; the array side pops one per clk_array
// edge and feeds a bubble when it is empty. A row's sums come back through a
// second one, and the pop of a row is what arr_valid was. The sequencer
// reads its next entry only when the input FIFO has room for it and for the
// one read in flight, and a row of A only with a credit (rows sent minus
// rows received below OUT_DEPTH): the array cannot be stalled, so its
// output FIFO must never be full. A tile still starts after the last write
// of the one before, which keeps the shadow weights still behind a swap
// whatever the clocks. The array side's reset is rst_array_i, synchronous to
// clk_array_i (gemm_accel.sv makes both resets). ARRAY_CDC = 0 is the direct path,
// cycle for cycle the Phase G sequencer (CYCLES = job_cycles()).
module gemm_accel_seq #(
    parameter  int unsigned ROWS    = 16,
    parameter  int unsigned COLS    = 16,
    parameter  int unsigned A_LINES = 1024,
    parameter  int unsigned W_LINES = 1024,
    parameter  int unsigned C_LINES = 256,
    parameter  int unsigned DIM_W   = 16,
    parameter  bit          ARRAY_CDC   = 1'b0,
    parameter  int unsigned IN_DEPTH    = 16,  // ARRAY_CDC: entries to the array
    parameter  int unsigned OUT_DEPTH   = 32,  // ARRAY_CDC: rows of sums back
    parameter  int unsigned SYNC_STAGES = 2,   // ARRAY_CDC: synchronizer flops
    localparam int unsigned A_AW    = $clog2(A_LINES),
    localparam int unsigned W_AW    = $clog2(W_LINES),
    localparam int unsigned C_AW    = $clog2(C_LINES),
    localparam int unsigned DATA_W  = 8,
    localparam int unsigned ACC_W   = 32
) (
    input  logic                       clk_i,
    input  logic                       rst_i,
    input  logic                       clk_array_i,   // the array's, if ARRAY_CDC
    input  logic                       rst_array_i,   // ARRAY_CDC: on clk_array_i

    input  logic                       start_i,
    input  logic [DIM_W-1:0]           m_i,
    input  logic [DIM_W-1:0]           k_i,
    input  logic [DIM_W-1:0]           n_i,
    output logic                       busy_o,
    output logic                       done_o,     // one cycle, job finished
    output logic                       error_o,    // one cycle, shape refused

    output logic [A_AW-1:0]            a_raddr_o,
    input  logic [ROWS*DATA_W-1:0]     a_rdata_i,
    output logic [W_AW-1:0]            w_raddr_o,
    input  logic [COLS*DATA_W-1:0]     w_rdata_i,
    output logic [C_AW-1:0]            c_raddr_o,
    input  logic [COLS*ACC_W-1:0]      c_rdata_i,
    output logic                       c_we_o,
    output logic [C_AW-1:0]            c_waddr_o,
    output logic [COLS*ACC_W-1:0]      c_wdata_o
);

  localparam int unsigned LOG_R = $clog2(ROWS);
  localparam int unsigned LOG_C = $clog2(COLS);
  localparam int unsigned CNT_W = 2 * DIM_W;   // products and line numbers

  if ((1 << LOG_R) != ROWS || (1 << LOG_C) != COLS) begin : g_pow2
    $error("gemm_accel_seq: ROWS and COLS must be powers of two");
  end

  typedef enum logic [2:0] {S_IDLE, S_CHK0, S_CHK1, S_CHK2, S_LOAD, S_SWAP, S_STREAM, S_DRAIN}
      state_t;
  state_t state_q;

  logic [DIM_W-1:0] m_q, k_q, n_q;
  logic [DIM_W-1:0] kt_n_q, nt_n_q;            // tiles along K and N
  logic             zero_q;
  logic [CNT_W-1:0] use_a_q, use_w_q, use_c_q;  // lines each matrix needs
  logic [CNT_W-1:0] w_back_q;                   // (ROWS - 1) * NT

  // loop position
  logic [DIM_W-1:0] nt_q, kt_q;
  logic [DIM_W-1:0] col_base_q;                 // nt * COLS
  logic [DIM_W-1:0] k_base_q;                   // kt * ROWS
  logic [LOG_R-1:0] li_q;                       // LOAD: row of the tile
  logic [DIM_W-1:0] mi_q;                       // STREAM: row of A
  logic [CNT_W-1:0] w_tile_q;                   // W line of the tile's row 0
  logic [CNT_W-1:0] w_addr_q, a_addr_q;

  // output side
  logic [CNT_W-1:0] c_ptr_q;                    // C line of the next row out
  logic [DIM_W-1:0] out_cnt_q;                  // rows written this tile

  logic last_out, tile_end, last_kt, last_nt;

  // ---- the array's inputs, one cycle behind the reads ----
  logic             valid_q, swap_q, shift_q, row_ok_q;
  logic [COLS-1:0]  colmask_q;

  // adv: the next entry may be read this cycle (always, unless ARRAY_CDC)
  logic             adv, issue;
  assign issue = adv && (state_q == S_LOAD || state_q == S_SWAP || state_q == S_STREAM);

  logic [COLS-1:0]  colmask;
  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      colmask[c] = ({{(CNT_W-DIM_W){1'b0}}, col_base_q} + CNT_W'(c)) < {{(CNT_W-DIM_W){1'b0}}, n_q};
    end
  end

  logic [CNT_W-1:0] k_row;
  assign k_row = {{(CNT_W-DIM_W){1'b0}}, k_base_q} + {{(CNT_W-LOG_R){1'b0}}, li_q};

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_q   <= 1'b0;
      swap_q    <= 1'b0;
      shift_q   <= 1'b0;
      row_ok_q  <= 1'b0;
      colmask_q <= '0;
    end else begin
      valid_q   <= issue && state_q == S_STREAM;
      swap_q    <= issue && state_q == S_SWAP;
      shift_q   <= issue && state_q == S_LOAD;
      row_ok_q  <= k_row < {{(CNT_W-DIM_W){1'b0}}, k_q};
      colmask_q <= colmask;
    end
  end

  logic [COLS-1:0][DATA_W-1:0] w_in;
  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      w_in[c] = (row_ok_q && colmask_q[c]) ? w_rdata_i[c*DATA_W +: DATA_W] : '0;
    end
  end

  logic                        arr_valid;
  logic [COLS-1:0][ACC_W-1:0]  arr_c;

  if (!ARRAY_CDC) begin : g_direct
    assign adv = 1'b1;

    systolic_array #(
        .ROWS   (ROWS),
        .COLS   (COLS),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) u_array (
        .clk_i     (clk_i),
        .rst_i     (rst_i),
        .valid_i   (valid_q),
        .swap_i    (swap_q),
        .a_i       (a_rdata_i),
        .w_i       (w_in),
        .w_shift_i (shift_q),
        .valid_o   (arr_valid),
        .c_o       (arr_c)
    );

    logic unused_direct;
    assign unused_direct = clk_array_i ^ rst_array_i;
  end else begin : g_cdc
    localparam int unsigned ENT_W  = 3 + ROWS * DATA_W + COLS * DATA_W;
    localparam int unsigned SUM_W  = COLS * ACC_W;
    localparam int unsigned IN_PW  = $clog2(IN_DEPTH) + 1;
    localparam int unsigned OUT_PW = $clog2(OUT_DEPTH) + 1;
    localparam int unsigned CRED_W = $clog2(OUT_DEPTH + 1);

    // -- core side: push what the direct path would feed the array
    logic              pend;              // an entry read last cycle, pushed now
    logic [IN_PW-1:0]  in_used;
    logic              in_full;
    logic [CRED_W-1:0] cred_q;            // rows sent - rows received
    logic              out_empty;
    logic              room, credit;

    assign pend   = valid_q || swap_q || shift_q;
    assign room   = ({1'b0, in_used} + {{IN_PW{1'b0}}, pend}) < (IN_PW + 1)'(IN_DEPTH);
    assign credit = cred_q < CRED_W'(OUT_DEPTH);
    assign adv    = room && (state_q != S_STREAM || credit);
    assign arr_valid = !out_empty;        // a row of sums, popped this cycle

    always_ff @(posedge clk_i) begin
      if (rst_i) cred_q <= '0;
      else       cred_q <= cred_q + CRED_W'(issue && state_q == S_STREAM) - CRED_W'(arr_valid);
    end

    // -- array side
    logic                       rst_a;
    assign rst_a = rst_array_i;
    logic                       in_empty;
    logic [ENT_W-1:0]           ent;
    logic                       a_valid, a_swap, a_shift;
    logic [ROWS*DATA_W-1:0]     a_a;
    logic [COLS-1:0][DATA_W-1:0] a_w;
    logic                       a_valid_o;
    logic [COLS-1:0][ACC_W-1:0] a_c;
    logic                       out_full;
    logic [OUT_PW-1:0]          out_used;

`ifdef FORMAL
    logic [IN_PW-1:0]                    f_in_wptr, f_in_rptr;
    logic [IN_DEPTH-1:0][ENT_W-1:0]      f_in_mem;
    logic [OUT_PW-1:0]                   f_out_wptr, f_out_rptr;
    logic [OUT_DEPTH-1:0][SUM_W-1:0]     f_out_mem;
`endif

    cdc_async_fifo #(
        .WIDTH       (ENT_W),
        .DEPTH       (IN_DEPTH),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_in (
        .wr_clk_i   (clk_i),
        .wr_rst_i   (rst_i),
        .wr_en_i    (pend),
        .wr_data_i  ({valid_q, swap_q, shift_q, a_rdata_i, w_in}),
        .wr_full_o  (in_full),
        .wr_used_o  (in_used),
        .rd_clk_i   (clk_array_i),
        .rd_rst_i   (rst_a),
        .rd_en_i    (!in_empty),
        .rd_data_o  (ent),
        .rd_empty_o (in_empty)
`ifdef FORMAL
        ,
        .f_wptr_o   (f_in_wptr),
        .f_rptr_o   (f_in_rptr),
        .f_mem_o    (f_in_mem)
`endif
    );

    // an empty FIFO feeds a bubble: nothing valid, no swap, no shift
    assign {a_valid, a_swap, a_shift, a_a, a_w} = ent;

    systolic_array #(
        .ROWS   (ROWS),
        .COLS   (COLS),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) u_array (
        .clk_i     (clk_array_i),
        .rst_i     (rst_a),
        .valid_i   (a_valid && !in_empty),
        .swap_i    (a_swap && !in_empty),
        .a_i       (a_a),
        .w_i       (a_w),
        .w_shift_i (a_shift && !in_empty),
        .valid_o   (a_valid_o),
        .c_o       (a_c)
    );

    cdc_async_fifo #(
        .WIDTH       (SUM_W),
        .DEPTH       (OUT_DEPTH),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_out (
        .wr_clk_i   (clk_array_i),
        .wr_rst_i   (rst_a),
        .wr_en_i    (a_valid_o),
        .wr_data_i  (a_c),
        .wr_full_o  (out_full),
        .wr_used_o  (out_used),
        .rd_clk_i   (clk_i),
        .rd_rst_i   (rst_i),
        .rd_en_i    (arr_valid),
        .rd_data_o  (arr_c),
        .rd_empty_o (out_empty)
`ifdef FORMAL
        ,
        .f_wptr_o   (f_out_wptr),
        .f_rptr_o   (f_out_rptr),
        .f_mem_o    (f_out_mem)
`endif
    );

`ifdef FORMAL
    // Neither FIFO is ever written while full (a write would be dropped):
    // the input by room (the read in flight counted), the output by
    // credits. Checked in every simulation (cocotb builds with FORMAL).
    always_comb begin
      if (!rst_i && !rst_a) begin
        assert (!(pend && in_full));
        assert (!(a_valid_o && out_full));
      end
    end
    logic unused_f;
    assign unused_f = ^{f_in_wptr, f_in_rptr, f_in_mem, f_out_wptr, f_out_rptr, f_out_mem};
`endif
    logic unused_cdc;
    assign unused_cdc = ^{in_full, out_full, out_used};
  end

  // ---- reads ----
  assign a_raddr_o = a_addr_q[A_AW-1:0];
  assign w_raddr_o = w_addr_q[W_AW-1:0];
  assign c_raddr_o = c_ptr_q[C_AW-1:0];

  // ---- behind the array: sums registered while the old line is read ----
  logic                        o2_q;
  logic [COLS-1:0][ACC_W-1:0]  sum_q;
  logic [C_AW-1:0]             c_waddr_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      o2_q      <= 1'b0;
      sum_q     <= '0;
      c_waddr_q <= '0;
    end else begin
      o2_q <= arr_valid;
      if (arr_valid) begin
        sum_q     <= arr_c;
        c_waddr_q <= c_ptr_q[C_AW-1:0];
      end
    end
  end

  logic first_kt;
  assign first_kt = kt_q == '0;

  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      c_wdata_o[c*ACC_W +: ACC_W] = sum_q[c] + (first_kt ? '0 : c_rdata_i[c*ACC_W +: ACC_W]);
    end
  end
  assign c_we_o    = o2_q;
  assign c_waddr_o = c_waddr_q;

  // ---- control ----
  function automatic logic shape_ok();
    return !zero_q && use_a_q <= CNT_W'(A_LINES) && use_w_q <= CNT_W'(W_LINES)
           && use_c_q <= CNT_W'(C_LINES);
  endfunction

  assign last_out = o2_q && out_cnt_q == m_q - 1'b1;
  assign last_kt  = kt_q == kt_n_q - 1'b1;
  assign last_nt  = nt_q == nt_n_q - 1'b1;
  assign tile_end = state_q == S_DRAIN && last_out;

  assign busy_o  = state_q != S_IDLE;
  assign done_o  = tile_end && last_kt && last_nt;
  assign error_o = state_q == S_CHK2 && !shape_ok();

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q    <= S_IDLE;
      m_q        <= '0;
      k_q        <= '0;
      n_q        <= '0;
      kt_n_q     <= '0;
      nt_n_q     <= '0;
      zero_q     <= 1'b0;
      use_a_q    <= '0;
      use_w_q    <= '0;
      use_c_q    <= '0;
      w_back_q   <= '0;
      nt_q       <= '0;
      kt_q       <= '0;
      col_base_q <= '0;
      k_base_q   <= '0;
      li_q       <= '0;
      mi_q       <= '0;
      w_tile_q   <= '0;
      w_addr_q   <= '0;
      a_addr_q   <= '0;
      c_ptr_q    <= '0;
      out_cnt_q  <= '0;
    end else begin
      if (arr_valid) c_ptr_q <= c_ptr_q + {{(CNT_W-DIM_W){1'b0}}, nt_n_q};
      if (o2_q)      out_cnt_q <= out_cnt_q + 1'b1;

      case (state_q)
        S_IDLE: if (start_i) begin
          m_q     <= m_i;
          k_q     <= k_i;
          n_q     <= n_i;
          state_q <= S_CHK0;
        end
        S_CHK0: begin
          kt_n_q  <= DIM_W'(({1'b0, k_q} + (DIM_W+1)'(ROWS - 1)) >> LOG_R);
          nt_n_q  <= DIM_W'(({1'b0, n_q} + (DIM_W+1)'(COLS - 1)) >> LOG_C);
          zero_q  <= m_q == '0 || k_q == '0 || n_q == '0;
          state_q <= S_CHK1;
        end
        S_CHK1: begin
          use_a_q  <= CNT_W'(m_q) * CNT_W'(kt_n_q);
          use_w_q  <= CNT_W'(k_q) * CNT_W'(nt_n_q);
          use_c_q  <= CNT_W'(m_q) * CNT_W'(nt_n_q);
          w_back_q <= ({{(CNT_W-DIM_W){1'b0}}, nt_n_q} << LOG_R) - {{(CNT_W-DIM_W){1'b0}}, nt_n_q};
          state_q  <= S_CHK2;
        end
        S_CHK2: begin
          if (!shape_ok()) begin
            state_q <= S_IDLE;
          end else begin
            nt_q       <= '0;
            kt_q       <= '0;
            col_base_q <= '0;
            k_base_q   <= '0;
            w_tile_q   <= '0;
            start_tile('0, '0);
          end
        end
        S_LOAD: if (adv) begin
          w_addr_q <= w_addr_q - {{(CNT_W-DIM_W){1'b0}}, nt_n_q};
          li_q     <= li_q - 1'b1;
          if (li_q == '0) state_q <= S_SWAP;
        end
        S_SWAP: if (adv) begin
          mi_q     <= '0;
          a_addr_q <= {{(CNT_W-DIM_W){1'b0}}, kt_q};
          state_q  <= S_STREAM;
        end
        S_STREAM: if (adv) begin
          a_addr_q <= a_addr_q + {{(CNT_W-DIM_W){1'b0}}, kt_n_q};
          mi_q     <= mi_q + 1'b1;
          if (mi_q == m_q - 1'b1) state_q <= S_DRAIN;
        end
        S_DRAIN: if (last_out) begin
          if (!last_kt) begin
            kt_q     <= kt_q + 1'b1;
            k_base_q <= k_base_q + DIM_W'(ROWS);
            w_tile_q <= w_tile_q + ({{(CNT_W-DIM_W){1'b0}}, nt_n_q} << LOG_R);
            start_tile(w_tile_q + ({{(CNT_W-DIM_W){1'b0}}, nt_n_q} << LOG_R), nt_q);
          end else if (!last_nt) begin
            nt_q       <= nt_q + 1'b1;
            kt_q       <= '0;
            k_base_q   <= '0;
            col_base_q <= col_base_q + DIM_W'(COLS);
            w_tile_q   <= {{(CNT_W-DIM_W){1'b0}}, nt_q + 1'b1};
            start_tile({{(CNT_W-DIM_W){1'b0}}, nt_q + 1'b1}, nt_q + 1'b1);
          end else begin
            state_q <= S_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // Enter LOAD for the tile whose row 0 is W line w_tile, in column tile
  // nt: the load starts at its row ROWS - 1; C from line nt.
  task automatic start_tile(input logic [CNT_W-1:0] w_tile, input logic [DIM_W-1:0] nt);
    w_addr_q  <= w_tile + w_back_q;
    li_q      <= LOG_R'(ROWS - 1);
    c_ptr_q   <= {{(CNT_W-DIM_W){1'b0}}, nt};
    out_cnt_q <= '0;
    state_q   <= S_LOAD;
  endtask

  // Line numbers wrap in the buffers' address widths: past K the reads are
  // masked, and an accepted shape never needs more.
  logic unused_seq;
  assign unused_seq = ^{a_addr_q[CNT_W-1:A_AW], w_addr_q[CNT_W-1:W_AW], c_ptr_q[CNT_W-1:C_AW]};

endmodule
