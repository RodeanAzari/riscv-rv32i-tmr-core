// Triple modular redundancy around the core (CLAUDE.md 5.7).
//
// Three copies of riscv_core run in lockstep on the same clock, reset and
// memory read data. Everything they would change -- the fetch address, the
// data-memory access, the register-file write, the halt flags -- goes through
// one 2-of-3 voter (tmr_voter.sv, formally verified), and the voted values
// are both what the outside world sees and what every copy loads back into
// its own pc, halt flags and register file (riscv_core's VOTED feedback). So
// a fault in one copy is outvoted on the cycle it shows, and the copy is
// pulled back into step: its pc follows the vote at once, its register file
// is rewritten by every voted write, and its pipeline refills from the voted
// fetch address. What feedback cannot repair is a flipped register-file bit
// that is never written again: that copy keeps a wrong value there until
// software rewrites the register, and is outvoted whenever it is used.
//
// The voter sees what each copy would commit next, so mismatch_o is "some
// copy would commit something different" (see the masking at the bundle).
// mismatch_count_o counts episodes -- cycles where a mismatch begins -- so
// one fault reads as one, however long its effects take to drain; it
// saturates, and lags mismatch_o by a cycle. disagree_o says which copy is
// out.
//
// DONT_TOUCH and KEEP_HIERARCHY on the copies: without them Vivado sees three
// identical cores fed identical inputs, merges them into one, and the
// redundancy silently disappears. docs/reports/utilization_*_tmr.rpt is the
// evidence that three survive.
//
// The ports are riscv_core's plus TMR status and the injector, so the core's
// own tests run on this unchanged (inject_pc_i left at 0). The debug and RVFI
// ports are copy A's: a view of one copy, not the vote.
//
// inject_pc_i is the live fault injector (soc.sv's TMR register): its set
// bits are flipped in copy B's pc as it loads the voted next pc, so B's pc
// register holds a wrong value for a cycle -- a real fault in a real flop,
// the same kind the fault campaign deposits in simulation. All zero, nothing
// happens.
module riscv_core_tmr #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5
) (
    input  logic            clk_i,
    input  logic            rst_i,

    output logic [XLEN-1:0] imem_addr_o,
    input  logic [XLEN-1:0] imem_rdata_i,
    output logic [XLEN-1:0] dmem_addr_o,
    output logic [XLEN-1:0] dmem_wdata_o,
    output logic [3:0]      dmem_wstrb_o,
    output logic            dmem_we_o,
    output logic            dmem_re_o,
    input  logic [XLEN-1:0] dmem_rdata_i,

    output logic              wb_rd_we_o,
    output logic [ADDR_W-1:0] wb_rd_addr_o,
    output logic [XLEN-1:0]   wb_rd_wdata_o,
    output logic              halt_o,

    // TMR status.
    output logic              mismatch_o,        // the copies disagree this cycle
    output logic [2:0]        disagree_o,        // which: bit i = copy i
    output logic [31:0]       mismatch_count_o,  // disagreements begun since reset
    input  logic [XLEN-1:0]   inject_pc_i,       // bits to flip in copy B's pc

`ifdef RISCV_FORMAL
    output logic              rvfi_valid_o,
    output logic [63:0]       rvfi_order_o,
    output logic [XLEN-1:0]   rvfi_insn_o,
    output logic              rvfi_trap_o,
    output logic              rvfi_halt_o,
    output logic              rvfi_intr_o,
    output logic [ADDR_W-1:0] rvfi_rs1_addr_o,
    output logic [ADDR_W-1:0] rvfi_rs2_addr_o,
    output logic [XLEN-1:0]   rvfi_rs1_rdata_o,
    output logic [XLEN-1:0]   rvfi_rs2_rdata_o,
    output logic [ADDR_W-1:0] rvfi_rd_addr_o,
    output logic [XLEN-1:0]   rvfi_rd_wdata_o,
    output logic [XLEN-1:0]   rvfi_pc_rdata_o,
    output logic [XLEN-1:0]   rvfi_pc_wdata_o,
    output logic [XLEN-1:0]   rvfi_mem_addr_o,
    output logic [3:0]        rvfi_mem_rmask_o,
    output logic [3:0]        rvfi_mem_wmask_o,
    output logic [XLEN-1:0]   rvfi_mem_rdata_o,
    output logic [XLEN-1:0]   rvfi_mem_wdata_o,
`endif

    output logic [XLEN-1:0]   if_id_pc_o,
    output logic [XLEN-1:0]   if_id_instr_o,
    output logic [XLEN-1:0]   id_ex_pc_o,
    output logic [XLEN-1:0]   id_ex_instr_o,
    output logic [ADDR_W-1:0] id_ex_rs1_addr_o,
    output logic [ADDR_W-1:0] id_ex_rs2_addr_o,
    output logic [XLEN-1:0]   id_ex_rs1_rdata_o,
    output logic [XLEN-1:0]   id_ex_rs2_rdata_o,
    output logic [XLEN-1:0]   id_ex_imm_o,
    output logic [ADDR_W-1:0] id_ex_rd_addr_o,
    output logic [XLEN-1:0]   ex_mem_pc_o,
    output logic [XLEN-1:0]   ex_mem_instr_o,
    output logic [XLEN-1:0]   ex_mem_alu_result_o,
    output logic [ADDR_W-1:0] ex_mem_rd_addr_o,
    output logic              ex_mem_rd_we_o,
    output logic [XLEN-1:0]   mem_wb_pc_o,
    output logic [XLEN-1:0]   mem_wb_instr_o
);

  // What each copy would do next, as one bundle per copy, and the vote on it.
  localparam int unsigned VW = 3 * XLEN + 4 + 1 + 1 + 1 + ADDR_W + XLEN + 2 + 1;

  logic [XLEN-1:0]   imem_addr [3];
  logic [XLEN-1:0]   dmem_addr [3];
  logic [XLEN-1:0]   dmem_wdata[3];
  logic [3:0]        dmem_wstrb[3];
  logic              dmem_we   [3];
  logic              dmem_re   [3];
  logic              rd_we     [3];
  logic [ADDR_W-1:0] rd_addr   [3];
  logic [XLEN-1:0]   rd_wdata  [3];
  logic [1:0]        halt_next [3];
  logic              halt      [3];
  logic [VW-1:0]     bundle    [3];

  logic [XLEN-1:0]   v_imem_addr, v_dmem_addr, v_dmem_wdata, v_rd_wdata;
  logic [3:0]        v_dmem_wstrb;
  logic              v_dmem_we, v_dmem_re, v_rd_we, v_halt;
  logic [ADDR_W-1:0] v_rd_addr;
  logic [1:0]        v_halt_next;

  // Store data only counts when there is a store, and a register write's
  // address and data only when there is a write: the core drives them every
  // cycle (the store data path is EX's rs2, whatever the instruction), and a
  // copy differing only in a value nobody will commit is not a fault worth
  // a mismatch. Likewise the data address, which the core computes for every
  // instruction, counts only for a load or a store (dmem_re/we). The memory
  // and the register files ignore these fields otherwise, so masking changes
  // nothing they see.
  for (genvar i = 0; i < 3; i++) begin : g_copy
    assign bundle[i] = {imem_addr[i], dmem_addr[i] & {XLEN{dmem_we[i] | dmem_re[i]}},
                        dmem_wdata[i] & {XLEN{dmem_we[i]}}, dmem_wstrb[i],
                        dmem_we[i], dmem_re[i], rd_we[i],
                        rd_addr[i] & {ADDR_W{rd_we[i]}}, rd_wdata[i] & {XLEN{rd_we[i]}},
                        halt_next[i], halt[i]};
  end

  tmr_voter #(.W(VW)) u_voter (
      .a_i        (bundle[0]),
      .b_i        (bundle[1]),
      .c_i        (bundle[2]),
      .y_o        ({v_imem_addr, v_dmem_addr, v_dmem_wdata, v_dmem_wstrb,
                    v_dmem_we, v_dmem_re, v_rd_we, v_rd_addr, v_rd_wdata,
                    v_halt_next, v_halt}),
      .mismatch_o (mismatch_o),
      .disagree_o (disagree_o)
  );

  assign imem_addr_o   = v_imem_addr;
  assign dmem_addr_o   = v_dmem_addr;
  assign dmem_wdata_o  = v_dmem_wdata;
  assign dmem_wstrb_o  = v_dmem_wstrb;
  assign dmem_we_o     = v_dmem_we;
  assign dmem_re_o     = v_dmem_re;
  assign wb_rd_we_o    = v_rd_we;
  assign wb_rd_addr_o  = v_rd_addr;
  assign wb_rd_wdata_o = v_rd_wdata;
  assign halt_o        = v_halt;

  // ---- the copies ----
  // Copy A drives the debug and RVFI ports; B's and C's are left open.
  /* verilator lint_off PINCONNECTEMPTY */
  (* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "TRUE" *)
  riscv_core #(.XLEN(XLEN), .ADDR_W(ADDR_W), .VOTED(1'b1)) u_core_a (
      .clk_i (clk_i), .rst_i (rst_i),
`ifdef FORMAL
      .f_regs_o (),
`endif
      .imem_addr_o (imem_addr[0]), .imem_rdata_i (imem_rdata_i),
      .dmem_addr_o (dmem_addr[0]), .dmem_wdata_o (dmem_wdata[0]),
      .dmem_wstrb_o (dmem_wstrb[0]), .dmem_we_o (dmem_we[0]), .dmem_re_o (dmem_re[0]),
      .dmem_rdata_i (dmem_rdata_i),
      .wb_rd_we_o (rd_we[0]), .wb_rd_addr_o (rd_addr[0]), .wb_rd_wdata_o (rd_wdata[0]),
      .halt_o (halt[0]), .halt_next_o (halt_next[0]),
      .vote_pc_i (v_imem_addr), .vote_halt_i (v_halt_next),
      .vote_rd_we_i (v_rd_we), .vote_rd_addr_i (v_rd_addr), .vote_rd_wdata_i (v_rd_wdata),
`ifdef RISCV_FORMAL
      .rvfi_valid_o (rvfi_valid_o), .rvfi_order_o (rvfi_order_o), .rvfi_insn_o (rvfi_insn_o),
      .rvfi_trap_o (rvfi_trap_o), .rvfi_halt_o (rvfi_halt_o), .rvfi_intr_o (rvfi_intr_o),
      .rvfi_rs1_addr_o (rvfi_rs1_addr_o), .rvfi_rs2_addr_o (rvfi_rs2_addr_o),
      .rvfi_rs1_rdata_o (rvfi_rs1_rdata_o), .rvfi_rs2_rdata_o (rvfi_rs2_rdata_o),
      .rvfi_rd_addr_o (rvfi_rd_addr_o), .rvfi_rd_wdata_o (rvfi_rd_wdata_o),
      .rvfi_pc_rdata_o (rvfi_pc_rdata_o), .rvfi_pc_wdata_o (rvfi_pc_wdata_o),
      .rvfi_mem_addr_o (rvfi_mem_addr_o), .rvfi_mem_rmask_o (rvfi_mem_rmask_o),
      .rvfi_mem_wmask_o (rvfi_mem_wmask_o), .rvfi_mem_rdata_o (rvfi_mem_rdata_o),
      .rvfi_mem_wdata_o (rvfi_mem_wdata_o),
`endif
      .if_id_pc_o (if_id_pc_o), .if_id_instr_o (if_id_instr_o),
      .id_ex_pc_o (id_ex_pc_o), .id_ex_instr_o (id_ex_instr_o),
      .id_ex_rs1_addr_o (id_ex_rs1_addr_o), .id_ex_rs2_addr_o (id_ex_rs2_addr_o),
      .id_ex_rs1_rdata_o (id_ex_rs1_rdata_o), .id_ex_rs2_rdata_o (id_ex_rs2_rdata_o),
      .id_ex_imm_o (id_ex_imm_o), .id_ex_rd_addr_o (id_ex_rd_addr_o),
      .ex_mem_pc_o (ex_mem_pc_o), .ex_mem_instr_o (ex_mem_instr_o),
      .ex_mem_alu_result_o (ex_mem_alu_result_o), .ex_mem_rd_addr_o (ex_mem_rd_addr_o),
      .ex_mem_rd_we_o (ex_mem_rd_we_o),
      .mem_wb_pc_o (mem_wb_pc_o), .mem_wb_instr_o (mem_wb_instr_o)
  );

  for (genvar i = 1; i < 3; i++) begin : g_other
    (* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "TRUE" *)
    riscv_core #(.XLEN(XLEN), .ADDR_W(ADDR_W), .VOTED(1'b1)) u_core (
        .clk_i (clk_i), .rst_i (rst_i),
`ifdef FORMAL
        .f_regs_o (),
`endif
        .imem_addr_o (imem_addr[i]), .imem_rdata_i (imem_rdata_i),
        .dmem_addr_o (dmem_addr[i]), .dmem_wdata_o (dmem_wdata[i]),
        .dmem_wstrb_o (dmem_wstrb[i]), .dmem_we_o (dmem_we[i]), .dmem_re_o (dmem_re[i]),
        .dmem_rdata_i (dmem_rdata_i),
        .wb_rd_we_o (rd_we[i]), .wb_rd_addr_o (rd_addr[i]), .wb_rd_wdata_o (rd_wdata[i]),
        .halt_o (halt[i]), .halt_next_o (halt_next[i]),
        .vote_pc_i (i == 1 ? v_imem_addr ^ inject_pc_i : v_imem_addr),
        .vote_halt_i (v_halt_next),
        .vote_rd_we_i (v_rd_we), .vote_rd_addr_i (v_rd_addr), .vote_rd_wdata_i (v_rd_wdata),
`ifdef RISCV_FORMAL
        .rvfi_valid_o (), .rvfi_order_o (), .rvfi_insn_o (), .rvfi_trap_o (), .rvfi_halt_o (),
        .rvfi_intr_o (), .rvfi_rs1_addr_o (), .rvfi_rs2_addr_o (), .rvfi_rs1_rdata_o (),
        .rvfi_rs2_rdata_o (), .rvfi_rd_addr_o (), .rvfi_rd_wdata_o (), .rvfi_pc_rdata_o (),
        .rvfi_pc_wdata_o (), .rvfi_mem_addr_o (), .rvfi_mem_rmask_o (), .rvfi_mem_wmask_o (),
        .rvfi_mem_rdata_o (), .rvfi_mem_wdata_o (),
`endif
        .if_id_pc_o (), .if_id_instr_o (), .id_ex_pc_o (), .id_ex_instr_o (),
        .id_ex_rs1_addr_o (), .id_ex_rs2_addr_o (), .id_ex_rs1_rdata_o (),
        .id_ex_rs2_rdata_o (), .id_ex_imm_o (), .id_ex_rd_addr_o (),
        .ex_mem_pc_o (), .ex_mem_instr_o (), .ex_mem_alu_result_o (),
        .ex_mem_rd_addr_o (), .ex_mem_rd_we_o (), .mem_wb_pc_o (), .mem_wb_instr_o ()
    );
  end
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- the mismatch counter ----
  // Counts from mismatch_o registered, not mismatch_o itself: the compare
  // across the whole bundle is a deep OR tree, and feeding it straight into
  // the counter's enable made that the critical path (OOC, 2026-10-18). The
  // count lands a cycle later; nothing reads it that fast.
  logic mismatch_q, mismatch_q2;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      mismatch_q       <= 1'b0;
      mismatch_q2      <= 1'b0;
      mismatch_count_o <= '0;
    end else begin
      mismatch_q  <= mismatch_o;
      mismatch_q2 <= mismatch_q;
      if (mismatch_q && !mismatch_q2 && (mismatch_count_o != '1))
        mismatch_count_o <= mismatch_count_o + 32'd1;
    end
  end

endmodule
