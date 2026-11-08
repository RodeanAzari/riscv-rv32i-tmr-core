// Prints AMD's DRP counter words for every integer divide (50 % duty, phase
// 0), from clk_wiz's mmcm_pll_drp_func_7s_mmcm.vh (the XAPP888 reference),
// in sw/model/mmcm_drp.py --table's format: d reg1 reg2, REG1 without bit 12
// (kept by the read-modify-write, not computed). make aclk-check compares the
// two. The function file is read from the Vivado install, not copied.
module amd_divider_table;
`include "mmcm_pll_drp_func_7s_mmcm.vh"
  reg [37:0] w;
  integer d;
  initial begin
    for (d = 1; d <= 128; d = d + 1) begin
      w = mmcm_pll_count_calc(d[7:0], 0, 50000);
      $display("%0d %04x %04x", d, w[15:0] & 16'hEFFF, w[31:16]);
    end
    $finish;
  end
endmodule
