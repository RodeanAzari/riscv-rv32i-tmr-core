// GEMM accelerator (Phase G): the systolic array with its own buffers, a
// sequencer that runs a whole C = A @ W, and two bus ports. Golden model:
// sw/model/accel_model.py, which also has the buffer layouts.
//
// Decided with the user (2026-11-05): the buffers are local, banked so the
// array reads a whole line (ROWS activations, COLS weights, COLS sums) a
// cycle, and the DMA moves data between them and RAM; the bus is 4 bytes a
// cycle and could not keep the array fed. C is INT32.
//
//   s_*  AXI4-Lite, the registers (gemm_accel_regs.sv), OFF_W bits of offset
//   d_*  AXI4, the buffers: A at 0, W at BUF_BYTES, C at 2 * BUF_BYTES, the
//        fourth slot reads 0; INCR bursts of full-width beats, one beat at a
//        time (axi_ram_port.sv). While a job runs the buffers are the
//        engine's and a bus access waits for it to end.
//
// Each buffer is 32-bit banks of ram_dp: an A line (ROWS bytes) is ROWS/4
// banks side by side, a W line COLS/4, a C line COLS. Port A of every bank is
// the engine's read; port B is the bus's, or while busy the engine's C write.
module gemm_accel #(
    parameter  int unsigned ROWS      = 16,
    parameter  int unsigned COLS      = 16,
    parameter  int unsigned BUF_BYTES = 16384,
    parameter  int unsigned OFF_W     = 12,
    localparam int unsigned ADDR_W    = 32,
    localparam int unsigned DATA_W    = 32,
    localparam int unsigned STRB_W    = DATA_W / 8
) (
    input  logic              clk_i,
    input  logic              rst_i,

    // registers, AXI4-Lite
    input  logic [OFF_W-1:0]  s_awaddr_i,
    input  logic              s_awvalid_i,
    output logic              s_awready_o,
    input  logic [DATA_W-1:0] s_wdata_i,
    input  logic [STRB_W-1:0] s_wstrb_i,
    input  logic              s_wvalid_i,
    output logic              s_wready_o,
    output logic [1:0]        s_bresp_o,
    output logic              s_bvalid_o,
    input  logic              s_bready_i,
    input  logic [OFF_W-1:0]  s_araddr_i,
    input  logic              s_arvalid_i,
    output logic              s_arready_o,
    output logic [DATA_W-1:0] s_rdata_o,
    output logic [1:0]        s_rresp_o,
    output logic              s_rvalid_o,
    input  logic              s_rready_i,

    // buffers, AXI4
    input  logic [ADDR_W-1:0] d_araddr_i,
    input  logic [7:0]        d_arlen_i,
    input  logic [2:0]        d_arsize_i,
    input  logic [1:0]        d_arburst_i,
    input  logic              d_arvalid_i,
    output logic              d_arready_o,
    output logic [DATA_W-1:0] d_rdata_o,
    output logic [1:0]        d_rresp_o,
    output logic              d_rlast_o,
    output logic              d_rvalid_o,
    input  logic              d_rready_i,
    input  logic [ADDR_W-1:0] d_awaddr_i,
    input  logic [7:0]        d_awlen_i,
    input  logic [2:0]        d_awsize_i,
    input  logic [1:0]        d_awburst_i,
    input  logic              d_awvalid_i,
    output logic              d_awready_o,
    input  logic [DATA_W-1:0] d_wdata_i,
    input  logic [STRB_W-1:0] d_wstrb_i,
    input  logic              d_wlast_i,
    input  logic              d_wvalid_i,
    output logic              d_wready_o,
    output logic [1:0]        d_bresp_o,
    output logic              d_bvalid_o,
    input  logic              d_bready_i
);

  localparam int unsigned DIM_W   = 16;
  localparam int unsigned NB_A    = ROWS / 4;           // banks per line
  localparam int unsigned NB_W    = COLS / 4;
  localparam int unsigned NB_C    = COLS;
  localparam int unsigned A_LINES = BUF_BYTES / ROWS;
  localparam int unsigned W_LINES = BUF_BYTES / COLS;
  localparam int unsigned C_LINES = BUF_BYTES / (4 * COLS);
  localparam int unsigned A_AW    = $clog2(A_LINES);
  localparam int unsigned W_AW    = $clog2(W_LINES);
  localparam int unsigned C_AW    = $clog2(C_LINES);
  localparam int unsigned SLOT_W  = $clog2(BUF_BYTES / 4);   // word in a buffer
  localparam int unsigned WIN_W   = SLOT_W + 2;              // word in the window

  localparam logic [1:0] SLOT_A = 2'd0;
  localparam logic [1:0] SLOT_W_ = 2'd1;
  localparam logic [1:0] SLOT_C = 2'd2;

  if (ROWS % 4 != 0 || COLS % 4 != 0) begin : g_lanes
    $error("gemm_accel: ROWS and COLS must be multiples of 4 (32-bit banks)");
  end

  // ---- registers and sequencer ----
  logic             start, busy, done, error;
  logic [DIM_W-1:0] m, k, n;

  gemm_accel_regs #(
      .OFF_W (OFF_W),
      .DIM_W (DIM_W)
  ) u_regs (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_awaddr_i  (s_awaddr_i),
      .s_awvalid_i (s_awvalid_i),
      .s_awready_o (s_awready_o),
      .s_wdata_i   (s_wdata_i),
      .s_wstrb_i   (s_wstrb_i),
      .s_wvalid_i  (s_wvalid_i),
      .s_wready_o  (s_wready_o),
      .s_bresp_o   (s_bresp_o),
      .s_bvalid_o  (s_bvalid_o),
      .s_bready_i  (s_bready_i),
      .s_araddr_i  (s_araddr_i),
      .s_arvalid_i (s_arvalid_i),
      .s_arready_o (s_arready_o),
      .s_rdata_o   (s_rdata_o),
      .s_rresp_o   (s_rresp_o),
      .s_rvalid_o  (s_rvalid_o),
      .s_rready_i  (s_rready_i),
      .start_o     (start),
      .m_o         (m),
      .k_o         (k),
      .n_o         (n),
      .busy_i      (busy),
      .done_i      (done),
      .error_i     (error)
  );

  logic [A_AW-1:0]       e_a_raddr;
  logic [W_AW-1:0]       e_w_raddr;
  logic [C_AW-1:0]       e_c_raddr, e_c_waddr;
  logic [ROWS*8-1:0]     e_a_rdata;
  logic [COLS*8-1:0]     e_w_rdata;
  logic [COLS*32-1:0]    e_c_rdata, e_c_wdata;
  logic                  e_c_we;

  gemm_accel_seq #(
      .ROWS    (ROWS),
      .COLS    (COLS),
      .A_LINES (A_LINES),
      .W_LINES (W_LINES),
      .C_LINES (C_LINES),
      .DIM_W   (DIM_W)
  ) u_seq (
      .clk_i     (clk_i),
      .rst_i     (rst_i),
      .start_i   (start),
      .m_i       (m),
      .k_i       (k),
      .n_i       (n),
      .busy_o    (busy),
      .done_o    (done),
      .error_o   (error),
      .a_raddr_o (e_a_raddr),
      .a_rdata_i (e_a_rdata),
      .w_raddr_o (e_w_raddr),
      .w_rdata_i (e_w_rdata),
      .c_raddr_o (e_c_raddr),
      .c_rdata_i (e_c_rdata),
      .c_we_o    (e_c_we),
      .c_waddr_o (e_c_waddr),
      .c_wdata_o (e_c_wdata)
  );

  // ---- the bus side: one word at a time, waiting while busy ----
  logic              bus_en;
  logic [WIN_W-1:0]  bus_addr;
  logic [STRB_W-1:0] bus_we;
  logic [DATA_W-1:0] bus_wdata, bus_rdata;

  axi_ram_port #(
      .WORDS (1 << WIN_W)
  ) u_port (
      .clk_i       (clk_i),
      .rst_i       (rst_i),
      .s_araddr_i  (d_araddr_i),
      .s_arlen_i   (d_arlen_i),
      .s_arsize_i  (d_arsize_i),
      .s_arburst_i (d_arburst_i),
      .s_arvalid_i (d_arvalid_i),
      .s_arready_o (d_arready_o),
      .s_rdata_o   (d_rdata_o),
      .s_rresp_o   (d_rresp_o),
      .s_rlast_o   (d_rlast_o),
      .s_rvalid_o  (d_rvalid_o),
      .s_rready_i  (d_rready_i),
      .s_awaddr_i  (d_awaddr_i),
      .s_awlen_i   (d_awlen_i),
      .s_awsize_i  (d_awsize_i),
      .s_awburst_i (d_awburst_i),
      .s_awvalid_i (d_awvalid_i),
      .s_awready_o (d_awready_o),
      .s_wdata_i   (d_wdata_i),
      .s_wstrb_i   (d_wstrb_i),
      .s_wlast_i   (d_wlast_i),
      .s_wvalid_i  (d_wvalid_i),
      .s_wready_o  (d_wready_o),
      .s_bresp_o   (d_bresp_o),
      .s_bvalid_o  (d_bvalid_o),
      .s_bready_i  (d_bready_i),
      .core_busy_i (busy),
      .ram_en_o    (bus_en),
      .ram_addr_o  (bus_addr),
      .ram_we_o    (bus_we),
      .ram_wdata_o (bus_wdata),
      .ram_rdata_i (bus_rdata)
  );

  // which buffer and which word in it
  logic [1:0]        bus_slot;
  logic [SLOT_W-1:0] bus_word;
  assign bus_slot = bus_addr[WIN_W-1:SLOT_W];
  assign bus_word = bus_addr[SLOT_W-1:0];

  // a read's word arrives next cycle: remember which bank to return
  logic [1:0]        rd_slot_q;
  logic [SLOT_W-1:0] rd_word_q;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      rd_slot_q <= '0;
      rd_word_q <= '0;
    end else if (bus_en) begin
      rd_slot_q <= bus_slot;
      rd_word_q <= bus_word;
    end
  end

  // ---- the banks ----
  logic [NB_A-1:0][31:0] a_b_rdata;
  logic [NB_W-1:0][31:0] w_b_rdata;
  logic [NB_C-1:0][31:0] c_b_rdata;

  for (genvar b = 0; b < NB_A; b++) begin : g_a
    logic [3:0] we;
    assign we = (bus_en && bus_slot == SLOT_A && 32'(bus_word) % NB_A == b) ? bus_we : '0;
    ram_dp #(.WORDS (A_LINES)) u_bank (
        .clk_i     (clk_i),
        .a_addr_i  (e_a_raddr),
        .a_rdata_o (e_a_rdata[32*b +: 32]),
        .b_addr_i  (A_AW'(32'(bus_word) / NB_A)),
        .b_we_i    (we),
        .b_wdata_i (bus_wdata),
        .b_rdata_o (a_b_rdata[b])
    );
  end

  for (genvar b = 0; b < NB_W; b++) begin : g_w
    logic [3:0] we;
    assign we = (bus_en && bus_slot == SLOT_W_ && 32'(bus_word) % NB_W == b) ? bus_we : '0;
    ram_dp #(.WORDS (W_LINES)) u_bank (
        .clk_i     (clk_i),
        .a_addr_i  (e_w_raddr),
        .a_rdata_o (e_w_rdata[32*b +: 32]),
        .b_addr_i  (W_AW'(32'(bus_word) / NB_W)),
        .b_we_i    (we),
        .b_wdata_i (bus_wdata),
        .b_rdata_o (w_b_rdata[b])
    );
  end

  for (genvar b = 0; b < NB_C; b++) begin : g_c
    logic [3:0] we;
    assign we = busy ? {4{e_c_we}}
              : (bus_en && bus_slot == SLOT_C && 32'(bus_word) % NB_C == b) ? bus_we : '0;
    ram_dp #(.WORDS (C_LINES)) u_bank (
        .clk_i     (clk_i),
        .a_addr_i  (e_c_raddr),
        .a_rdata_o (e_c_rdata[32*b +: 32]),
        .b_addr_i  (busy ? e_c_waddr : C_AW'(32'(bus_word) / NB_C)),
        .b_we_i    (we),
        .b_wdata_i (busy ? e_c_wdata[32*b +: 32] : bus_wdata),
        .b_rdata_o (c_b_rdata[b])
    );
  end

  always_comb begin
    case (rd_slot_q)
      SLOT_A:  bus_rdata = a_b_rdata[32'(rd_word_q) % NB_A];
      SLOT_W_: bus_rdata = w_b_rdata[32'(rd_word_q) % NB_W];
      SLOT_C:  bus_rdata = c_b_rdata[32'(rd_word_q) % NB_C];
      default: bus_rdata = '0;
    endcase
  end

endmodule
