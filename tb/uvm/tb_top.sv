// UVM testbench top: riscv_core, its interface, and the probes.
//
// The core is compiled with RISCV_FORMAL for its RVFI port. The probes reach
// into the core by hierarchical name -- testbench only; rtl/ is unchanged.
`timescale 1ns / 1ps

module tb_top;
  import uvm_pkg::*;
  import rv_pkg::*;

  logic clk = 1'b0;
  always #10 clk = ~clk;   // 50 MHz, as on the board

  core_if cif (clk);

  riscv_core dut (
      .clk_i               (clk),
      .rst_i               (cif.rst),
      .imem_addr_o         (cif.imem_addr),
      .imem_rdata_i        (cif.imem_rdata),
      .dmem_addr_o         (cif.dmem_addr),
      .dmem_wdata_o        (cif.dmem_wdata),
      .dmem_wstrb_o        (cif.dmem_wstrb),
      .dmem_we_o           (cif.dmem_we),
      .dmem_re_o           (),
      .dmem_rdata_i        (cif.dmem_rdata),
      .wb_rd_we_o          (cif.wb_rd_we),
      .wb_rd_addr_o        (cif.wb_rd_addr),
      .wb_rd_wdata_o       (),
      .halt_o              (cif.halt),
      // Not voted: VOTED = 0, so the vote inputs are ignored.
      .halt_next_o         (),
      .vote_pc_i           ('0),
      .vote_halt_i         ('0),
      .vote_rd_we_i        (1'b0),
      .vote_rd_addr_i      ('0),
      .vote_rd_wdata_i     ('0),
      .rvfi_valid_o        (cif.rvfi_valid),
      .rvfi_order_o        (cif.rvfi_order),
      .rvfi_insn_o         (cif.rvfi_insn),
      .rvfi_trap_o         (cif.rvfi_trap),
      .rvfi_halt_o         (cif.rvfi_halt),
      .rvfi_intr_o         (cif.rvfi_intr),
      .rvfi_rs1_addr_o     (cif.rvfi_rs1_addr),
      .rvfi_rs2_addr_o     (cif.rvfi_rs2_addr),
      .rvfi_rs1_rdata_o    (cif.rvfi_rs1_rdata),
      .rvfi_rs2_rdata_o    (cif.rvfi_rs2_rdata),
      .rvfi_rd_addr_o      (cif.rvfi_rd_addr),
      .rvfi_rd_wdata_o     (cif.rvfi_rd_wdata),
      .rvfi_pc_rdata_o     (cif.rvfi_pc_rdata),
      .rvfi_pc_wdata_o     (cif.rvfi_pc_wdata),
      .rvfi_mem_addr_o     (cif.rvfi_mem_addr),
      .rvfi_mem_rmask_o    (cif.rvfi_mem_rmask),
      .rvfi_mem_wmask_o    (cif.rvfi_mem_wmask),
      .rvfi_mem_rdata_o    (cif.rvfi_mem_rdata),
      .rvfi_mem_wdata_o    (cif.rvfi_mem_wdata),
      .if_id_pc_o          (),
      .if_id_instr_o       (cif.if_id_instr),
      .id_ex_pc_o          (),
      .id_ex_instr_o       (cif.id_ex_instr),
      .id_ex_rs1_addr_o    (),
      .id_ex_rs2_addr_o    (),
      .id_ex_rs1_rdata_o   (),
      .id_ex_rs2_rdata_o   (),
      .id_ex_imm_o         (),
      .id_ex_rd_addr_o     (),
      .ex_mem_pc_o         (),
      .ex_mem_instr_o      (),
      .ex_mem_alu_result_o (),
      .ex_mem_rd_addr_o    (cif.ex_mem_rd_addr),
      .ex_mem_rd_we_o      (cif.ex_mem_rd_we),
      .mem_wb_pc_o         (),
      .mem_wb_instr_o      (cif.mem_wb_instr)
  );

  // ---- white-box probes ----
  assign cif.id_ex_valid    = dut.id_ex_valid;
  assign cif.if_id_valid    = dut.if_id_valid;
  assign cif.fwd_rs1_ex_mem = dut.id_ex_fwd_rs1_ex_mem;
  assign cif.fwd_rs1_mem_wb = dut.id_ex_fwd_rs1_mem_wb;
  assign cif.fwd_rs2_ex_mem = dut.id_ex_fwd_rs2_ex_mem;
  assign cif.fwd_rs2_mem_wb = dut.id_ex_fwd_rs2_mem_wb;
  assign cif.stall          = dut.stall;
  assign cif.redirect       = dut.redirect;

  // WB->ID bypass: decided in ID, used when that instruction is in EX one
  // cycle later. Registered unconditionally: if ID did not advance (stall,
  // flush), EX holds a bubble next cycle and the value is never read.
  always_ff @(posedge clk) begin
    cif.bypass_rs1 <= cif.wb_rd_we && (cif.wb_rd_addr != '0) && (cif.wb_rd_addr == dut.dec_rs1_addr);
    cif.bypass_rs2 <= cif.wb_rd_we && (cif.wb_rd_addr != '0) && (cif.wb_rd_addr == dut.dec_rs2_addr);
  end

  initial begin
    uvm_config_db#(virtual core_if)::set(null, "*", "vif", cif);
    run_test();
  end
endmodule
