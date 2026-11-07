// Board-level top for the Digilent Arty A7-100T: clocking, reset and pins
// around soc.sv. Pin assignments are in constr/arty_a7.xdc.
//
// Clock: the board's 100 MHz oscillator through an MMCM to 100 MHz (VCO
// 1000 MHz: x10, /10). First light ran at 50 MHz (/20), when a load's data
// went from the block RAM's output to the next instruction's branch
// comparator in one cycle; accessing data memory from EX took that path out
// (riscv_core.sv). The MMCM stays, rather than the oscillator directly: it
// is where the clock is chosen, and its deskew is part of the timing.
//
// Reset: held while the red RESET button (active low) is pressed or the MMCM
// is not locked, and for RST_HOLD clocks after both clear. The request is
// synchronised first -- both sources are asynchronous to the core clock --
// and the release then shifts in a 1 per clock. Out of configuration the
// chain is all zeros (a Xilinx flop powers up to its INIT value, 0), so the
// core starts in reset with no initial value written in RTL.
//
// ILA: with ILA = 1 (make impl ILA=1) the core's pipeline registers and
// writeback, brought out by soc.sv, are marked for debug here, and
// syn/impl_arty.tcl attaches an Integrated Logic Analyzer to them. With
// ILA = 0, the default, they are left unconnected and trimmed, so the timing
// and utilization the reports track are the design's own.
//
// MMCME2_BASE and BUFG are Xilinx primitives. Lint reads stand-in models of
// them from tb/models/; Vivado uses the real ones. Simulation runs soc.sv,
// not this module.
module arty_a7_top #(
    parameter string INIT_FILE = "",
    parameter bit    ILA       = 1'b0,
    parameter bit    TMR       = 1'b0,    // three voted cores: soc.sv, make impl TMR=1
    parameter bit    M_EXT     = 1'b0     // RV32IM core(s): make impl M=1
) (
    input  logic       clk100_i,     // CLK100MHZ, E3
    input  logic       rst_ni,       // ck_rst, the RESET button, C2
    output logic [3:0] led_o,        // led[3:0], LD4-LD7
    output logic       uart_tx_o,    // uart_rxd_out, to the USB-UART bridge
    input  logic       uart_rx_i     // uart_txd_in, from the USB-UART bridge
);

  localparam int unsigned CLK_HZ   = 100_000_000;
  localparam int unsigned RST_HOLD = 4;

  // ---- clock ----
  logic clk_fb, clk_mmcm, clk, locked;

  MMCME2_BASE #(
      .CLKIN1_PERIOD    (10.0),
      .DIVCLK_DIVIDE    (1),
      .CLKFBOUT_MULT_F  (10.0),
      .CLKOUT0_DIVIDE_F (10.0)
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
  // Unread in RTL: only the ILA reads them, and only when ILA = 1. The
  // waiver runs to the end of the probe block below.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] if_id_pc, if_id_instr, id_ex_pc, id_ex_instr;
  logic [31:0] ex_mem_pc, ex_mem_instr, ex_mem_alu_result;
  logic [31:0] mem_wb_pc, mem_wb_instr, wb_rd_wdata;
  logic [4:0]  wb_rd_addr;
  logic        wb_rd_we, halt;

  soc #(
      .CLK_HZ    (CLK_HZ),
      .INIT_FILE (INIT_FILE),
      .TMR       (TMR),
      .M_EXT     (M_EXT)
  ) u_soc (
      .clk_i                   (clk),
      .rst_i                   (rst),
      .led_o                   (led_o),
      .uart_tx_o               (uart_tx_o),
      .uart_rx_i               (uart_rx_i),
      .dbg_if_id_pc_o          (if_id_pc),
      .dbg_if_id_instr_o       (if_id_instr),
      .dbg_id_ex_pc_o          (id_ex_pc),
      .dbg_id_ex_instr_o       (id_ex_instr),
      .dbg_ex_mem_pc_o         (ex_mem_pc),
      .dbg_ex_mem_instr_o      (ex_mem_instr),
      .dbg_ex_mem_alu_result_o (ex_mem_alu_result),
      .dbg_mem_wb_pc_o         (mem_wb_pc),
      .dbg_mem_wb_instr_o      (mem_wb_instr),
      .dbg_wb_rd_we_o          (wb_rd_we),
      .dbg_wb_rd_addr_o        (wb_rd_addr),
      .dbg_wb_rd_wdata_o       (wb_rd_wdata),
      .dbg_halt_o              (halt)
  );

  // The probe nets. Their names are the probe names Hardware Manager shows
  // (prefixed g_ila.), so they are named after the pipeline register.
  if (ILA) begin : g_ila
    (* mark_debug = "true" *) logic [31:0] if_id_pc_p, if_id_instr_p;
    (* mark_debug = "true" *) logic [31:0] id_ex_pc_p, id_ex_instr_p;
    (* mark_debug = "true" *) logic [31:0] ex_mem_pc_p, ex_mem_instr_p, ex_mem_alu_result_p;
    (* mark_debug = "true" *) logic [31:0] mem_wb_pc_p, mem_wb_instr_p;
    (* mark_debug = "true" *) logic [31:0] wb_rd_wdata_p;
    (* mark_debug = "true" *) logic [4:0]  wb_rd_addr_p;
    (* mark_debug = "true" *) logic        wb_rd_we_p, halt_p;
    assign if_id_pc_p          = if_id_pc;
    assign if_id_instr_p       = if_id_instr;
    assign id_ex_pc_p          = id_ex_pc;
    assign id_ex_instr_p       = id_ex_instr;
    assign ex_mem_pc_p         = ex_mem_pc;
    assign ex_mem_instr_p      = ex_mem_instr;
    assign ex_mem_alu_result_p = ex_mem_alu_result;
    assign mem_wb_pc_p         = mem_wb_pc;
    assign mem_wb_instr_p      = mem_wb_instr;
    assign wb_rd_wdata_p       = wb_rd_wdata;
    assign wb_rd_addr_p        = wb_rd_addr;
    assign wb_rd_we_p          = wb_rd_we;
    assign halt_p              = halt;
  end
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
