// Weight-stationary systolic array, ROWS x COLS PEs (docs/buildplan.md 6.1).
// Golden model: systolic() in sw/model/gemm_model.py, same dataflow.
//
// One tile at a time: the PEs hold W[k0 + r][n0 + c], a row of A goes in as
// one vector (a_i[r] = A[m][k0 + r]) and its ROWS-term partial sums come out
// as one vector (c_o[c] for column n0 + c). Inside, row r of the input is
// delayed r cycles and column c of the output COLS - 1 - c cycles, so the
// diagonal wavefront of the array is invisible at the ports: a row's results
// leave LATENCY = ROWS + COLS - 1 clock edges after it enters, with valid_o.
// Rows enter back to back, one per cycle.
//
// The feeder in front of the array supplies zeros past the edges of A and W
// (lanes beyond K, columns beyond N), so the array always computes full
// tiles; summing tiles along K happens behind it.
//
// Weights (double-buffered in the PEs): while w_shift_i is high, w_i shifts
// one row of the next tile into the top of the shadow registers and every
// row moves down one, so after ROWS shifts row r holds the r-th row loaded
// counting from the bottom (load W[k0 + ROWS - 1] first). swap_i marks an
// input row (valid or not) after which the shadow weights become active;
// it travels with the data, so each PE switches right after that row has
// passed through it. The shadows must then stay put until the swap has
// reached the last PE, ROWS + COLS - 2 cycles later.
module systolic_array #(
    parameter int unsigned ROWS   = 4,
    parameter int unsigned COLS   = 4,
    parameter int unsigned DATA_W = 8,
    parameter int unsigned ACC_W  = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_i,
    input  logic                         valid_i,
    input  logic                         swap_i,
    input  logic [ROWS-1:0][DATA_W-1:0]  a_i,
    input  logic [COLS-1:0][DATA_W-1:0]  w_i,
    input  logic                         w_shift_i,
    output logic                         valid_o,
    output logic [COLS-1:0][ACC_W-1:0]   c_o
);

  localparam int unsigned LATENCY = ROWS + COLS - 1;

  // Grid wires: a and swap flow right, psum and weights flow down.
  logic [ROWS-1:0][COLS:0][DATA_W-1:0] a_h;
  logic [ROWS-1:0][COLS:0]             swap_h;
  logic [ROWS:0][COLS-1:0][ACC_W-1:0]  psum_v;
  logic [ROWS:0][COLS-1:0][DATA_W-1:0] w_v;

  assign psum_v[0] = '0;
  assign w_v[0]    = w_i;

  // What leaves the right edge and the bottom shadow row goes nowhere.
  // Named unused_* so lint knows it is deliberate.
  logic unused_edges;
  assign unused_edges = ^{w_v[ROWS], a_h[0][COLS], swap_h[0][COLS]};

  // Input skew: row r waits r cycles.
  for (genvar r = 0; r < ROWS; r++) begin : g_skew
    if (r == 0) begin : g_direct
      assign a_h[r][0]    = a_i[r];
      assign swap_h[r][0] = swap_i;
    end else begin : g_delay
      logic [r-1:0][DATA_W:0] sr_q;
      always_ff @(posedge clk_i) begin
        if (rst_i) begin
          sr_q <= '0;
        end else begin
          sr_q[0] <= {swap_i, a_i[r]};
          for (int i = 1; i < r; i++) sr_q[i] <= sr_q[i-1];
        end
      end
      assign {swap_h[r][0], a_h[r][0]} = sr_q[r-1];
    end
  end

  for (genvar r = 0; r < ROWS; r++) begin : g_row
    for (genvar c = 0; c < COLS; c++) begin : g_col
      systolic_pe #(
          .DATA_W(DATA_W),
          .ACC_W (ACC_W)
      ) u_pe (
          .clk_i    (clk_i),
          .rst_i    (rst_i),
          .a_i      (a_h[r][c]),
          .a_o      (a_h[r][c+1]),
          .psum_i   (psum_v[r][c]),
          .psum_o   (psum_v[r+1][c]),
          .w_i      (w_v[r][c]),
          .w_o      (w_v[r+1][c]),
          .w_shift_i(w_shift_i),
          .w_swap_i (swap_h[r][c]),
          .w_swap_o (swap_h[r][c+1])
      );
    end
  end

  // Output deskew: column c waits COLS - 1 - c cycles.
  for (genvar c = 0; c < COLS; c++) begin : g_deskew
    if (c == COLS - 1) begin : g_direct
      assign c_o[c] = psum_v[ROWS][c];
    end else begin : g_delay
      logic [COLS-2-c:0][ACC_W-1:0] sr_q;
      always_ff @(posedge clk_i) begin
        if (rst_i) begin
          sr_q <= '0;
        end else begin
          sr_q[0] <= psum_v[ROWS][c];
          for (int i = 1; i < COLS - 1 - c; i++) sr_q[i] <= sr_q[i-1];
        end
      end
      assign c_o[c] = sr_q[COLS-2-c];
    end
  end

  // valid_i, delayed to line up with c_o.
  logic [LATENCY-1:0] valid_q;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_q <= '0;
    end else begin
      valid_q[0] <= valid_i;
      for (int i = 1; i < LATENCY; i++) valid_q[i] <= valid_q[i-1];
    end
  end
  assign valid_o = valid_q[LATENCY-1];

endmodule
