// ASIC top for LibreLane run #2 (buildplan §6.4): the SoC as the board
// builds it by default (single core, RV32I, the array on the core clock,
// identity weight transform), with only the pins a chip would bring out.
//
//   clk_i      the one clock
//   rst_i      reset request, active high, asynchronous: asserted at once,
//              released through cdc_reset_sync on the clock
//   uart_*     the console (soc's UART receiver synchronises rx itself)
//   led_o      soc's LED register
//   halt_o     the core halted (a trap)
//
// The pipeline debug buses, the weight-transform hook's ports and the array
// clock's MMCM controls (unused with ARRAY_CDC = 0) are left off. The RAMs
// are sky130 SRAM macros when the flow defines SKY130_SRAM (ram_dp.sv);
// there is no boot ROM, so the RAM starts empty (a limitation of this run,
// which measures the physical design, not a chip that boots). The scan
// chains' ports are added by the flow (syn/librelane_plugin_scan).
module asic_top #(
    parameter int unsigned CLK_HZ = 20_000_000
) (
    input  logic       clk_i,
    input  logic       rst_i,
    output logic       uart_tx_o,
    input  logic       uart_rx_i,
    output logic [3:0] led_o,
    output logic       halt_o
);

  logic rst;

  // soc outputs this top does not bring out
  logic n_aclk_rst;
  logic n_drp_den;
  logic n_drp_dwe;
  logic [6:0] n_drp_daddr;
  logic [15:0] n_drp_di;
  logic n_wx_start;
  logic n_wx_valid;
  logic [15:0] n_wx_kt;
  logic [15:0] n_wx_nt;
  logic [3:0] n_wx_row;
  logic [15:0] n_wx_pad;
  logic [127:0] n_wx_w;
  logic [31:0] n_dbg_if_id_pc;
  logic [31:0] n_dbg_if_id_instr;
  logic [31:0] n_dbg_id_ex_pc;
  logic [31:0] n_dbg_id_ex_instr;
  logic [31:0] n_dbg_ex_mem_pc;
  logic [31:0] n_dbg_ex_mem_instr;
  logic [31:0] n_dbg_ex_mem_alu_result;
  logic [31:0] n_dbg_mem_wb_pc;
  logic [31:0] n_dbg_mem_wb_instr;
  logic n_dbg_wb_rd_we;
  logic [4:0] n_dbg_wb_rd_addr;
  logic [31:0] n_dbg_wb_rd_wdata;
  logic unused;
  assign unused = ^{n_aclk_rst, n_drp_den, n_drp_dwe, n_drp_daddr, n_drp_di, n_wx_start, n_wx_valid, n_wx_kt, n_wx_nt, n_wx_row, n_wx_pad, n_wx_w, n_dbg_if_id_pc, n_dbg_if_id_instr, n_dbg_id_ex_pc, n_dbg_id_ex_instr, n_dbg_ex_mem_pc, n_dbg_ex_mem_instr, n_dbg_ex_mem_alu_result, n_dbg_mem_wb_pc, n_dbg_mem_wb_instr, n_dbg_wb_rd_we, n_dbg_wb_rd_addr, n_dbg_wb_rd_wdata};

  cdc_reset_sync #(.STAGES (2)) u_rst (
      .clk_i  (clk_i),
      .arst_i (rst_i),
      .rst_o  (rst)
  );

  soc #(
      .CLK_HZ (CLK_HZ)
  ) u_soc (
      .clk_i                   (clk_i),
      .rst_i                   (rst),
      .clk_array_i             (clk_i),
      .aclk_rst_o              (n_aclk_rst),
      .aclk_locked_i           (1'b1),
      .drp_den_o               (n_drp_den),
      .drp_dwe_o               (n_drp_dwe),
      .drp_daddr_o             (n_drp_daddr),
      .drp_di_o                (n_drp_di),
      .drp_do_i                ('0),
      .drp_drdy_i              (1'b0),
      .wx_start_o              (n_wx_start),
      .wx_valid_o              (n_wx_valid),
      .wx_kt_o                 (n_wx_kt),
      .wx_nt_o                 (n_wx_nt),
      .wx_row_o                (n_wx_row),
      .wx_pad_o                (n_wx_pad),
      .wx_w_o                  (n_wx_w),
      .wx_w_i                  ('0),
      .led_o                   (led_o),
      .uart_tx_o               (uart_tx_o),
      .uart_rx_i               (uart_rx_i),
      .dbg_if_id_pc_o          (n_dbg_if_id_pc),
      .dbg_if_id_instr_o       (n_dbg_if_id_instr),
      .dbg_id_ex_pc_o          (n_dbg_id_ex_pc),
      .dbg_id_ex_instr_o       (n_dbg_id_ex_instr),
      .dbg_ex_mem_pc_o         (n_dbg_ex_mem_pc),
      .dbg_ex_mem_instr_o      (n_dbg_ex_mem_instr),
      .dbg_ex_mem_alu_result_o (n_dbg_ex_mem_alu_result),
      .dbg_mem_wb_pc_o         (n_dbg_mem_wb_pc),
      .dbg_mem_wb_instr_o      (n_dbg_mem_wb_instr),
      .dbg_wb_rd_we_o          (n_dbg_wb_rd_we),
      .dbg_wb_rd_addr_o        (n_dbg_wb_rd_addr),
      .dbg_wb_rd_wdata_o       (n_dbg_wb_rd_wdata),
      .dbg_halt_o              (halt_o)
  );

endmodule
