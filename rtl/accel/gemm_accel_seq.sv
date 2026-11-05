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
module gemm_accel_seq #(
    parameter  int unsigned ROWS    = 16,
    parameter  int unsigned COLS    = 16,
    parameter  int unsigned A_LINES = 1024,
    parameter  int unsigned W_LINES = 1024,
    parameter  int unsigned C_LINES = 256,
    parameter  int unsigned DIM_W   = 16,
    localparam int unsigned A_AW    = $clog2(A_LINES),
    localparam int unsigned W_AW    = $clog2(W_LINES),
    localparam int unsigned C_AW    = $clog2(C_LINES),
    localparam int unsigned DATA_W  = 8,
    localparam int unsigned ACC_W   = 32
) (
    input  logic                       clk_i,
    input  logic                       rst_i,

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
      valid_q   <= state_q == S_STREAM;
      swap_q    <= state_q == S_SWAP;
      shift_q   <= state_q == S_LOAD;
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
        S_LOAD: begin
          w_addr_q <= w_addr_q - {{(CNT_W-DIM_W){1'b0}}, nt_n_q};
          li_q     <= li_q - 1'b1;
          if (li_q == '0) state_q <= S_SWAP;
        end
        S_SWAP: begin
          mi_q     <= '0;
          a_addr_q <= {{(CNT_W-DIM_W){1'b0}}, kt_q};
          state_q  <= S_STREAM;
        end
        S_STREAM: begin
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
