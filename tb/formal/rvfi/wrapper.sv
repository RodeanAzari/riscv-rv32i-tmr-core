// riscv-formal wrapper: connects riscv_core to riscv-formal's checkers.
//
// riscv-formal instantiates a module named rvfi_wrapper, with clock, reset
// and the RVFI outputs (`RVFI_OUTPUTS), and checks the instruction stream it
// reports against the ISA spec. Everything else is this file's job: drive the
// core's other inputs, and adapt port names (CLAUDE.md 4's _i/_o suffixes).
//
// Both memories are FREE: rvformal_rand_reg makes imem_rdata and dmem_rdata a
// new arbitrary value every cycle. There is no memory model, deliberately.
// The checks relate what the core reports -- the instruction word it
// retired, the load data it saw (rvfi_mem_rdata) -- to what it did with
// them, so any instruction sequence and any memory contents are explored,
// not one program. rvfi_mem_rdata is this core's dmem_rdata_i in WB, the
// cycle a load consumes it, so the value checked is the value used.
//
// The core's RVFI port exists only under RISCV_FORMAL, which riscv-formal
// defines for every check.
module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);

  (* keep *) `rvformal_rand_reg [31:0] imem_rdata;
  (* keep *) `rvformal_rand_reg [31:0] dmem_rdata;

  (* keep *) wire [31:0] imem_addr;
  (* keep *) wire [31:0] dmem_addr;
  (* keep *) wire [31:0] dmem_wdata;
  (* keep *) wire [3:0]  dmem_wstrb;
  (* keep *) wire        dmem_we;
  (* keep *) wire        halt;

  riscv_core uut (
      .clk_i            (clock),
      .rst_i            (reset),

      .imem_addr_o      (imem_addr),
      .imem_rdata_i     (imem_rdata),

      .dmem_addr_o      (dmem_addr),
      .dmem_wdata_o     (dmem_wdata),
      .dmem_wstrb_o     (dmem_wstrb),
      .dmem_we_o        (dmem_we),
      .dmem_re_o        (),
      .dmem_rdata_i     (dmem_rdata),

      .wb_rd_we_o       (),
      .wb_rd_addr_o     (),
      .wb_rd_wdata_o    (),
      .halt_o           (halt),
      // Not voted: VOTED = 0, so the vote inputs are ignored.
      .halt_next_o      (),
      .vote_pc_i        ('0),
      .vote_halt_i      ('0),
      .vote_rd_we_i     (1'b0),
      .vote_rd_addr_i   ('0),
      .vote_rd_wdata_i  ('0),

      .rvfi_valid_o     (rvfi_valid),
      .rvfi_order_o     (rvfi_order),
      .rvfi_insn_o      (rvfi_insn),
      .rvfi_trap_o      (rvfi_trap),
      .rvfi_halt_o      (rvfi_halt),
      .rvfi_intr_o      (rvfi_intr),
      .rvfi_rs1_addr_o  (rvfi_rs1_addr),
      .rvfi_rs2_addr_o  (rvfi_rs2_addr),
      .rvfi_rs1_rdata_o (rvfi_rs1_rdata),
      .rvfi_rs2_rdata_o (rvfi_rs2_rdata),
      .rvfi_rd_addr_o   (rvfi_rd_addr),
      .rvfi_rd_wdata_o  (rvfi_rd_wdata),
      .rvfi_pc_rdata_o  (rvfi_pc_rdata),
      .rvfi_pc_wdata_o  (rvfi_pc_wdata),
      .rvfi_mem_addr_o  (rvfi_mem_addr),
      .rvfi_mem_rmask_o (rvfi_mem_rmask),
      .rvfi_mem_wmask_o (rvfi_mem_wmask),
      .rvfi_mem_rdata_o (rvfi_mem_rdata),
      .rvfi_mem_wdata_o (rvfi_mem_wdata),

      .if_id_pc_o          (),
      .if_id_instr_o       (),
      .id_ex_pc_o          (),
      .id_ex_instr_o       (),
      .id_ex_rs1_addr_o    (),
      .id_ex_rs2_addr_o    (),
      .id_ex_rs1_rdata_o   (),
      .id_ex_rs2_rdata_o   (),
      .id_ex_imm_o         (),
      .id_ex_rd_addr_o     (),
      .ex_mem_pc_o         (),
      .ex_mem_instr_o      (),
      .ex_mem_alu_result_o (),
      .ex_mem_rd_addr_o    (),
      .ex_mem_rd_we_o      (),
      .mem_wb_pc_o         (),
      .mem_wb_instr_o      ()
  );

  // Machine mode, 32-bit: the only privilege level and XLEN this core has.
  assign rvfi_mode = 2'd3;
  assign rvfi_ixl  = 2'd1;

endmodule
