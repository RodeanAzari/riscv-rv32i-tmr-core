// array_clk_ctl driving AMD's own MMCME2_ADV simulation model (the unisim in
// the Vivado install), set up as the board's array MMCM (arty_a7_top.sv
// g_array_clk: VCO 800 MHz, CLKOUT0 /8). tb/cocotb/test_aclk.py reprograms
// it through the register as software would and measures the clock that
// comes out. Icarus only (make aclk-check): the unisim is plain Verilog with
// timing, which Verilator does not run. DCLK is clk_i, as on the board.
`timescale 1ps / 1ps
module aclk_tb (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        clk100_i,
    input  logic        we_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        array_rst_o,
    output logic        clk_out_o,
    output logic        locked_o
);

  logic        mmcm_rst, den, dwe, drdy, clk_fb;
  logic [6:0]  daddr;
  logic [15:0] di, dout;

  array_clk_ctl u_ctl (
      .clk_i         (clk_i),
      .rst_i         (rst_i),
      .we_i          (we_i),
      .wdata_i       (wdata_i),
      .rdata_o       (rdata_o),
      .array_rst_o   (array_rst_o),
      .mmcm_rst_o    (mmcm_rst),
      .mmcm_locked_i (locked_o),
      .drp_den_o     (den),
      .drp_dwe_o     (dwe),
      .drp_daddr_o   (daddr),
      .drp_di_o      (di),
      .drp_do_i      (dout),
      .drp_drdy_i    (drdy)
  );

  MMCME2_ADV #(
      .CLKIN1_PERIOD    (10.0),
      .DIVCLK_DIVIDE    (1),
      .CLKFBOUT_MULT_F  (8.0),
      .CLKOUT0_DIVIDE_F (8.0)
  ) u_mmcm (
      .CLKIN1       (clk100_i),
      .CLKIN2       (1'b0),
      .CLKINSEL     (1'b1),
      .CLKFBIN      (clk_fb),
      .CLKFBOUT     (clk_fb),
      .CLKFBOUTB    (),
      .CLKFBSTOPPED (),
      .CLKINSTOPPED (),
      .CLKOUT0      (clk_out_o),
      .CLKOUT0B     (),
      .CLKOUT1      (),
      .CLKOUT1B     (),
      .CLKOUT2      (),
      .CLKOUT2B     (),
      .CLKOUT3      (),
      .CLKOUT3B     (),
      .CLKOUT4      (),
      .CLKOUT5      (),
      .CLKOUT6      (),
      .DCLK         (clk_i),
      .DADDR        (daddr),
      .DEN          (den),
      .DWE          (dwe),
      .DI           (di),
      .DO           (dout),
      .DRDY         (drdy),
      .PSCLK        (1'b0),
      .PSEN         (1'b0),
      .PSINCDEC     (1'b0),
      .PSDONE       (),
      .LOCKED       (locked_o),
      .PWRDWN       (1'b0),
      .RST          (mmcm_rst)
  );

endmodule
