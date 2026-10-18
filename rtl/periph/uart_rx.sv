// UART receiver: 8 data bits, no parity, 1 stop bit (8N1), LSB first.
//
// The other half of uart_tx.sv: the Arty's USB-UART bridge drives rx_i from
// the host's COM port, so the core can be sent programs (the bootloader) and
// keystrokes (interactive demos).
//
// Sampling: rx_i is asynchronous, so it passes two flops first. A falling
// edge starts a frame; half a bit later the line must still be low, or the
// edge was a glitch and is ignored. Each data bit and the stop bit are then
// sampled one bit time apart, in the middle of the bit. The stop bit's
// sample ends the frame, half a bit early, so a sender running slightly fast
// can start the next start bit without it being missed. Starting only on an
// edge also means a line held low (a break) is one framing error, not a
// stream of zero bytes.
//
// One byte of buffer. A complete frame with a high stop bit sets valid_o and
// data_o. ack_i (one cycle) clears valid_o and both error flags. A frame that
// completes while valid_o is still set is dropped and sets overrun_o -- the
// unread byte is kept. A frame whose stop bit is low is dropped and sets
// frame_err_o. Reading data_o has no side effect: the core's data port has no
// read enable, so only a write (ack_i) may change state.
module uart_rx #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_i,

    input  logic       rx_i,

    output logic [7:0] data_o,
    output logic       valid_o,
    output logic       overrun_o,
    output logic       frame_err_o,
    input  logic       ack_i
);

  localparam int unsigned CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;
  localparam int unsigned CNT_W        = $clog2(CLKS_PER_BIT);

  // Typed reload values: no size casts in RTL (Yosys has misparsed one; see
  // docs/formal-properties.md).
  localparam logic [CNT_W-1:0] CNT_RELOAD  = CLKS_PER_BIT[CNT_W-1:0] - 1'b1;
  localparam logic [CNT_W-1:0] HALF_RELOAD = CNT_RELOAD >> 1;

  if (100 * ((CLKS_PER_BIT * BAUD > CLK_HZ) ? CLKS_PER_BIT * BAUD - CLK_HZ
                                            : CLK_HZ - CLKS_PER_BIT * BAUD) >= CLK_HZ)
  begin : gen_baud_check
    $error("uart_rx: CLK_HZ / BAUD rounds to a bit time more than 1%% off");
  end

  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_START = 2'd1;
  localparam logic [1:0] S_DATA  = 2'd2;
  localparam logic [1:0] S_STOP  = 2'd3;

  logic [2:0]       sync_q;      // [1:0] synchroniser, [2] the previous sample
  logic [1:0]       state_q;
  logic [CNT_W-1:0] clk_cnt_q;   // clocks left to the next sample
  logic [2:0]       bit_q;       // data bit being received
  logic [7:0]       shift_q;     // data bits, shifted in LSB first
  logic [7:0]       data_q;
  logic             valid_q, overrun_q, frame_err_q;
  logic             rx, start_edge;

  assign rx         = sync_q[1];
  assign start_edge = sync_q[2] && !sync_q[1];

  assign data_o      = data_q;
  assign valid_o     = valid_q;
  assign overrun_o   = overrun_q;
  assign frame_err_o = frame_err_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) sync_q <= '1;           // idle line is high
    else       sync_q <= {sync_q[1:0], rx_i};
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q     <= S_IDLE;
      clk_cnt_q   <= '0;
      bit_q       <= '0;
      shift_q     <= '0;
      data_q      <= '0;
      valid_q     <= 1'b0;
      overrun_q   <= 1'b0;
      frame_err_q <= 1'b0;
    end else begin
      if (ack_i) begin
        valid_q     <= 1'b0;
        overrun_q   <= 1'b0;
        frame_err_q <= 1'b0;
      end
      case (state_q)
        S_IDLE: begin
          if (start_edge) begin
            state_q   <= S_START;
            clk_cnt_q <= HALF_RELOAD;
          end
        end
        S_START: begin
          if (clk_cnt_q != '0) begin
            clk_cnt_q <= clk_cnt_q - 1'b1;
          end else if (!rx) begin
            state_q   <= S_DATA;
            clk_cnt_q <= CNT_RELOAD;
            bit_q     <= '0;
          end else begin
            state_q   <= S_IDLE;        // a glitch, not a start bit
          end
        end
        S_DATA: begin
          if (clk_cnt_q != '0) begin
            clk_cnt_q <= clk_cnt_q - 1'b1;
          end else begin
            shift_q   <= {rx, shift_q[7:1]};
            clk_cnt_q <= CNT_RELOAD;
            if (bit_q == 3'd7) state_q <= S_STOP;
            else               bit_q   <= bit_q + 1'b1;
          end
        end
        default: begin                  // S_STOP
          if (clk_cnt_q != '0) begin
            clk_cnt_q <= clk_cnt_q - 1'b1;
          end else begin
            state_q <= S_IDLE;
            if (!rx) begin
              frame_err_q <= 1'b1;
            end else if (valid_q && !ack_i) begin
              overrun_q <= 1'b1;
            end else begin
              data_q  <= shift_q;
              valid_q <= 1'b1;
            end
          end
        end
      endcase
    end
  end

endmodule
