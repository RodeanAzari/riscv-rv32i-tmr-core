// Board-level top for the Digilent Arty A7-100T: clocking, reset and pins
// around soc.sv. Pin assignments are in constr/arty_a7.xdc.
//
// Clock: the board's 100 MHz oscillator through an MMCM to 50 MHz (VCO
// 1000 MHz: x10, /20). 50 MHz for first light because the out-of-context
// margin at 100 MHz is thin and the paths to the block RAM were never timed
// there; 100 MHz is a later, measured step.
//
// Reset: held while the red RESET button (active low) is pressed or the MMCM
// is not locked, and for RST_HOLD clocks after both clear. The request is
// synchronised first -- both sources are asynchronous to the core clock --
// and the release then shifts in a 1 per clock. Out of configuration the
// chain is all zeros (a Xilinx flop powers up to its INIT value, 0), so the
// core starts in reset with no initial value written in RTL.
//
// MMCME2_BASE and BUFG are Xilinx primitives. Lint reads stand-in models of
// them from tb/models/; Vivado uses the real ones. Simulation runs soc.sv,
// not this module.
module arty_a7_top #(
    parameter string INIT_FILE = ""
) (
    input  logic       clk100_i,     // CLK100MHZ, E3
    input  logic       rst_ni,       // ck_rst, the RESET button, C2
    output logic [3:0] led_o,        // led[3:0], LD4-LD7
    output logic       uart_tx_o     // uart_rxd_out, to the USB-UART bridge
);

  localparam int unsigned CLK_HZ   = 50_000_000;
  localparam int unsigned RST_HOLD = 4;

  // ---- clock ----
  logic clk_fb, clk_mmcm, clk, locked;

  MMCME2_BASE #(
      .CLKIN1_PERIOD    (10.0),
      .DIVCLK_DIVIDE    (1),
      .CLKFBOUT_MULT_F  (10.0),
      .CLKOUT0_DIVIDE_F (20.0)
  ) u_mmcm (
      .CLKIN1   (clk100_i),
      .CLKFBIN  (clk_fb),
      .CLKFBOUT (clk_fb),
      .CLKOUT0  (clk_mmcm),
      .LOCKED   (locked),
      .PWRDWN   (1'b0),
      .RST      (1'b0)
  );

  BUFG u_bufg (
      .I (clk_mmcm),
      .O (clk)
  );

  // ---- reset ----
  logic [1:0]          rst_req_q;    // synchroniser
  logic [RST_HOLD-1:0] rst_n_q;      // release delay; all zero = in reset
  logic                rst;

  always_ff @(posedge clk) begin
    rst_req_q <= {rst_req_q[0], !rst_ni || !locked};
    if (rst_req_q[1]) rst_n_q <= '0;
    else              rst_n_q <= {rst_n_q[RST_HOLD-2:0], 1'b1};
  end

  assign rst = !rst_n_q[RST_HOLD-1];

  // ---- the SoC ----
  soc #(
      .CLK_HZ    (CLK_HZ),
      .INIT_FILE (INIT_FILE)
  ) u_soc (
      .clk_i     (clk),
      .rst_i     (rst),
      .led_o     (led_o),
      .uart_tx_o (uart_tx_o)
  );

endmodule
