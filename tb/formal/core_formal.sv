// Formal harness for riscv_core's own properties (the `ifdef FORMAL block at
// the end of rtl/core/riscv_core.sv). The properties live in the RTL, beside
// the logic they describe; this file supplies only the environment.
//
// The environment is deliberately thin: every input is free -- any
// instruction word and any load data, every cycle -- and the one assumption
// is that the first cycle is a reset. After that the solver may also assert
// reset whenever it likes, so the properties must hold across resets too.
// Assumptions are where vacuous proofs come from, so they stay here, few and
// visible, and never in rtl/.
module core_formal (
    input logic        clk_i,
    input logic        rst_i,
    input logic [31:0] imem_rdata_i,
    input logic [31:0] dmem_rdata_i
);

  riscv_core u_core (
      .clk_i               (clk_i),
      .rst_i               (rst_i),
      .imem_addr_o         (),
      .imem_rdata_i        (imem_rdata_i),
      .dmem_addr_o         (),
      .dmem_wdata_o        (),
      .dmem_wstrb_o        (),
      .dmem_we_o           (),
      .dmem_re_o           (),
      .dmem_rdata_i        (dmem_rdata_i),
      .wb_rd_we_o          (),
      .wb_rd_addr_o        (),
      .wb_rd_wdata_o       (),
      .halt_o              (),
      // Not voted: VOTED = 0, so the vote inputs are ignored.
      .halt_next_o         (),
      .vote_pc_i           ('0),
      .vote_halt_i         ('0),
      .vote_rd_we_i        (1'b0),
      .vote_rd_addr_i      ('0),
      .vote_rd_wdata_i     ('0),
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

  // The one assumption: the first cycle is a reset.
  logic f_first = 1'b1;
  always_ff @(posedge clk_i) f_first <= 1'b0;
  always_comb if (f_first) assume (rst_i);

endmodule
