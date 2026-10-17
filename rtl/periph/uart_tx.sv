// UART transmitter: 8 data bits, no parity, 1 stop bit (8N1), LSB first.
//
// Transmit-only, because first light only needs the core to talk: the Arty's
// USB-UART bridge turns tx_o into a COM port on the host. A receiver can join
// it when something needs to send to the core.
//
// Handshake: the byte on data_i is taken on a cycle where valid_i and ready_o
// are both high. ready_o is low from that edge until the stop bit has been
// sent, so software polls it before each write.
//
// Bit timing is a counter of CLKS_PER_BIT clocks, rounded to the nearest
// integer. At 50 MHz and 115200 baud that is 434 clocks, 0.01% fast -- far
// inside the few percent a receiver tolerates. The elaboration check below
// rejects a clock/baud pair whose rounding error would not be.
module uart_tx #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_i,

    input  logic [7:0] data_i,
    input  logic       valid_i,
    output logic       ready_o,

    output logic       tx_o
);

  localparam int unsigned CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;
  localparam int unsigned CNT_W        = $clog2(CLKS_PER_BIT);
  localparam int unsigned FRAME_BITS   = 10;   // start, 8 data, stop

  // Typed reload values: no size casts in RTL (Yosys, which reads it for the
  // ASIC flow, has misparsed one; see docs/formal-properties.md).
  localparam logic [3:0]       FRAME_LEN  = 4'd10;
  localparam logic [CNT_W-1:0] CNT_RELOAD = CLKS_PER_BIT[CNT_W-1:0] - 1'b1;

  // |actual - nominal| / nominal under 1%, as integers: 100 * |CLKS_PER_BIT *
  // BAUD - CLK_HZ| < CLK_HZ.
  if (100 * ((CLKS_PER_BIT * BAUD > CLK_HZ) ? CLKS_PER_BIT * BAUD - CLK_HZ
                                            : CLK_HZ - CLKS_PER_BIT * BAUD) >= CLK_HZ)
  begin : gen_baud_check
    $error("uart_tx: CLK_HZ / BAUD rounds to a bit time more than 1%% off");
  end

  logic [FRAME_BITS-1:0] shift_q;     // the frame, shifted out LSB first
  logic [3:0]            bits_left_q; // frame bits still to send; 0 = idle
  logic [CNT_W-1:0]      clk_cnt_q;   // clocks left in the current bit

  assign ready_o = (bits_left_q == '0);
  assign tx_o    = ready_o ? 1'b1 : shift_q[0];   // idle line is high

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      shift_q     <= '1;
      bits_left_q <= '0;
      clk_cnt_q   <= '0;
    end else if (ready_o) begin
      if (valid_i) begin
        shift_q     <= {1'b1, data_i, 1'b0};
        bits_left_q <= FRAME_LEN;
        clk_cnt_q   <= CNT_RELOAD;
      end
    end else if (clk_cnt_q != '0) begin
      clk_cnt_q <= clk_cnt_q - 1'b1;
    end else begin
      shift_q     <= {1'b1, shift_q[FRAME_BITS-1:1]};
      bits_left_q <= bits_left_q - 1'b1;
      clk_cnt_q   <= CNT_RELOAD;
    end
  end

endmodule
