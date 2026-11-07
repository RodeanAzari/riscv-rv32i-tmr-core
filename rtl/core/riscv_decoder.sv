// RV32I instruction decode: register addresses, the immediate, and the control
// the EX, MEM and WB stages consume.
//
// FENCE decodes inert, which on this core is its full implementation: one
// in-order hart with no caches already performs memory accesses in program
// order. ECALL, EBREAK and every illegal instruction raise halt_o -- with no
// trap machinery in scope (CLAUDE.md 5.1) there is no handler to enter, so
// the core stops instead.
//
// Illegal means any word that is not one of the 40 RV32I encodings: other
// opcodes, reserved funct3/funct7 values, and the SYSTEM encodings this core
// does not implement (CSR accesses, MRET, WFI), FENCE.I (Zifencei) and the
// all-zero word. Besides halting, an illegal word decodes inert -- no register
// write, no memory access, no redirect -- so it retires with no effect but
// the trap, as riscv-formal's `ill` check requires.
//
// M_EXT (Phase H): the 8 M encodings (OP, funct7 0000001) become legal and
// raise muldiv_o, which sends the instruction to riscv_muldiv in EX. With
// M_EXT = 0, the default, they stay illegal and muldiv_o is constant 0.
//
// Register address fields sit at fixed positions in every RV32I format, so they
// are extracted unconditionally. Whether a given instruction actually *uses*
// rs1, rs2 or rd is answered by rd_we_o and the operand selects below; reading
// a field an instruction ignores is harmless, since the register file has no
// side effects on read.
module riscv_decoder #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5,
    parameter bit          M_EXT  = 1'b0
) (
    input  logic [XLEN-1:0]   instr_i,

    output logic [ADDR_W-1:0] rs1_addr_o,
    output logic [ADDR_W-1:0] rs2_addr_o,
    output logic [ADDR_W-1:0] rd_addr_o,
    output logic [XLEN-1:0]   imm_o,

    // EX control
    output logic [2:0]        funct3_o,
    output logic              alu_alt_o,
    output logic              alu_a_sel_pc_o,
    output logic              alu_a_sel_zero_o,
    output logic              alu_b_sel_imm_o,

    // Control flow, resolved in EX. branch_o: conditional, funct3 is the
    // condition. jump_o: JAL or JALR -- always taken, and rd gets the link
    // address pc + 4. jalr_o: the target is rs1 + imm rather than pc + imm.
    output logic              branch_o,
    output logic              jump_o,
    output logic              jalr_o,

    // MEM / WB control. mem_read_o doubles as the writeback select (load data
    // rather than the EX result). The link address of a jump is not a third
    // writeback source: it replaces the ALU result in EX, so it forwards from
    // EX/MEM like any other result.
    output logic              mem_read_o,
    output logic              mem_write_o,
    output logic [2:0]        mem_funct3_o,
    output logic              rd_we_o,
    // An M instruction (M_EXT only): EX takes its result from riscv_muldiv.
    output logic              muldiv_o,

    // ECALL, EBREAK or an illegal instruction: stop the core once
    // everything older has retired.
    output logic              halt_o
);

  // RV32I major opcodes (CLAUDE.md §5.1)
  localparam logic [6:0] OPCODE_LUI    = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPCODE_JAL    = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR   = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;
  localparam logic [6:0] OPCODE_LOAD   = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE  = 7'b0100011;
  localparam logic [6:0] OPCODE_OP     = 7'b0110011;
  localparam logic [6:0] OPCODE_OP_IMM = 7'b0010011;
  localparam logic [6:0] OPCODE_FENCE  = 7'b0001111;   // MISC-MEM

  // ECALL and EBREAK are whole-word encodings: SYSTEM with every other field
  // zero except imm[0], which tells them apart.
  localparam logic [31:0] INSTR_ECALL  = 32'h0000_0073;
  localparam logic [31:0] INSTR_EBREAK = 32'h0010_0073;

  localparam logic [2:0] F3_ADD_SUB = 3'b000;
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;

  // funct7 of the R-type and shift-immediate forms: all zero, or the alt bit
  // (SUB, SRA, SRAI) alone.
  localparam logic [6:0] F7_BASE = 7'b0000000;
  localparam logic [6:0] F7_ALT  = 7'b0100000;
  localparam logic [6:0] F7_MULDIV = 7'b0000001;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];

  assign rs1_addr_o = instr_i[19:15];
  assign rs2_addr_o = instr_i[24:20];
  assign rd_addr_o  = instr_i[11:7];

  // Load/store width and signedness, and a branch's condition. Not funct3_o:
  // for a load or store the ALU computes the address, so funct3_o must say ADD
  // and cannot also carry the width. Extracted unconditionally like the register fields; mem_read_o and
  // mem_write_o decide whether anything uses it.
  assign mem_funct3_o = funct3;


  // Immediate forms. Every one is sign-extended from instr[31] except U, which
  // is not an offset at all -- it supplies the upper 20 bits directly.
  //
  // The scrambled bit order in B and J is not arbitrary: RISC-V places each
  // immediate bit at a fixed position across formats wherever it can, so the
  // sign bit is always instr[31] and the hardware that extends it is shared.
  // The cost is that B and J look unreadable; the benefit is a smaller, faster
  // immediate mux. Both encode a 2-byte-aligned offset, so bit 0 is always 0
  // and is not stored.
  logic [XLEN-1:0] imm_i_type, imm_s_type, imm_b_type, imm_u_type, imm_j_type;

  assign imm_i_type = {{20{instr_i[31]}}, instr_i[31:20]};
  assign imm_s_type = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
  assign imm_b_type = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                       instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u_type = {instr_i[31:12], 12'b0};
  assign imm_j_type = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                       instr_i[20], instr_i[30:21], 1'b0};

  // R-type instructions have no immediate. They fall to the default and get the
  // I-form, which nothing downstream selects -- cheaper than a sixth mux input
  // that would only ever produce a value no one reads.
  always_comb begin
    case (opcode)
      OPCODE_LUI, OPCODE_AUIPC: imm_o = imm_u_type;
      OPCODE_JAL:               imm_o = imm_j_type;
      OPCODE_BRANCH:            imm_o = imm_b_type;
      OPCODE_STORE:             imm_o = imm_s_type;
      default:                  imm_o = imm_i_type;
    endcase
  end

  // The alt bit: SUB rather than ADD, SRA rather than SRL.
  //
  // For OP it is simply instr[30]. For OP-IMM it is instr[30] ONLY on the two
  // shift funct3 values, and zero everywhere else -- because on a non-shift
  // OP-IMM, instr[30] is not a mode bit at all, it is immediate bit 10.
  //
  // Get this wrong and `addi rd, rs1, -1` becomes a subtract: -1 encodes as
  // instr[31:20] = 0xFFF, so instr[30] is set. The instruction still decodes,
  // still writes a register, and produces a wrong answer only for negative
  // immediates -- which is why small random test values do not find it.
  logic op_imm_is_shift;
  assign op_imm_is_shift = (funct3 == F3_SLL) || (funct3 == F3_SRL_SRA);

  // Exactly the 40 RV32I encodings. Opcodes are compared in all seven bits,
  // so a word whose low two bits are not 11 (compressed, or all zeros) falls
  // to the default. SYSTEM is legal only as ECALL or EBREAK, compared as
  // whole words: the CSR instructions, MRET and WFI share the opcode.
  logic legal;
  always_comb begin
    case (opcode)
      OPCODE_LUI, OPCODE_AUIPC, OPCODE_JAL: legal = 1'b1;
      OPCODE_JALR:   legal = (funct3 == F3_ADD_SUB);
      OPCODE_BRANCH: legal = (funct3 != 3'b010) && (funct3 != 3'b011);
      // LB LH LW LBU LHU
      OPCODE_LOAD:   legal = (funct3 == 3'b000) || (funct3 == 3'b001) ||
                             (funct3 == 3'b010) || (funct3 == 3'b100) ||
                             (funct3 == 3'b101);
      // SB SH SW
      OPCODE_STORE:  legal = (funct3 == 3'b000) || (funct3 == 3'b001) ||
                             (funct3 == 3'b010);
      OPCODE_OP:     legal = (funct7 == F7_BASE) ||
                             ((funct7 == F7_ALT) &&
                              ((funct3 == F3_ADD_SUB) || (funct3 == F3_SRL_SRA))) ||
                             (M_EXT && (funct7 == F7_MULDIV));
      OPCODE_OP_IMM: legal = !op_imm_is_shift || (funct7 == F7_BASE) ||
                             ((funct7 == F7_ALT) && (funct3 == F3_SRL_SRA));
      OPCODE_FENCE:  legal = (funct3 == 3'b000);  // FENCE.I is Zifencei
      default:       legal = (instr_i == INSTR_ECALL) || (instr_i == INSTR_EBREAK);
    endcase
  end

  // Every funct3 under F7_MULDIV is an M instruction, so legal needs no more.
  assign muldiv_o = M_EXT && (opcode == OPCODE_OP) && (funct7 == F7_MULDIV);

  assign halt_o = !legal || (instr_i == INSTR_ECALL) || (instr_i == INSTR_EBREAK);

  always_comb begin
    // Safe defaults: compute ADD(0, imm) and write nothing. Any opcode not
    // handled below is therefore inert.
    funct3_o         = F3_ADD_SUB;
    alu_alt_o        = 1'b0;
    alu_a_sel_pc_o   = 1'b0;
    alu_a_sel_zero_o = 1'b1;
    alu_b_sel_imm_o  = 1'b1;
    branch_o         = 1'b0;
    jump_o           = 1'b0;
    jalr_o           = 1'b0;
    mem_read_o       = 1'b0;
    mem_write_o      = 1'b0;
    rd_we_o          = 1'b0;

    case (opcode)
      OPCODE_OP: begin
        funct3_o         = funct3;
        alu_alt_o        = instr_i[30];
        alu_a_sel_zero_o = 1'b0;      // rs1
        alu_b_sel_imm_o  = 1'b0;      // rs2
        rd_we_o          = 1'b1;
      end

      OPCODE_OP_IMM: begin
        funct3_o         = funct3;
        alu_alt_o        = op_imm_is_shift && instr_i[30];
        alu_a_sel_zero_o = 1'b0;      // rs1
        rd_we_o          = 1'b1;
      end

      // rd = 0 + imm. Reusing ADD with a zeroed operand costs nothing and
      // saves a pass-through path through the ALU.
      OPCODE_LUI: begin
        rd_we_o = 1'b1;
      end

      // rd = pc + imm
      OPCODE_AUIPC: begin
        alu_a_sel_pc_o   = 1'b1;
        alu_a_sel_zero_o = 1'b0;
        rd_we_o          = 1'b1;
      end

      // rd = mem[rs1 + imm]. The ALU computes the address with its default
      // ADD; the I-form immediate is already selected.
      OPCODE_LOAD: begin
        alu_a_sel_zero_o = 1'b0;      // rs1
        mem_read_o       = 1'b1;
        rd_we_o          = 1'b1;
      end

      // mem[rs1 + imm] = rs2. Same address path as a load, with the S-form
      // immediate. rs2 is the store data, not an ALU operand, so b stays on
      // the immediate.
      OPCODE_STORE: begin
        alu_a_sel_zero_o = 1'b0;      // rs1
        mem_write_o      = 1'b1;
      end

      // The ALU is idle for all three: the condition and target have their
      // own logic in EX, and a jump's link address replaces the ALU result.
      OPCODE_BRANCH: begin
        branch_o = 1'b1;
      end

      OPCODE_JAL: begin
        jump_o  = 1'b1;
        rd_we_o = 1'b1;
      end

      OPCODE_JALR: begin
        jump_o  = 1'b1;
        jalr_o  = 1'b1;
        rd_we_o = 1'b1;
      end

      default: ;  // inert: defaults above already write nothing
    endcase

    // An illegal word under a legal opcode (a reserved funct3 or funct7)
    // would otherwise act on the case above; it must only trap.
    if (!legal) begin
      branch_o    = 1'b0;
      jump_o      = 1'b0;
      jalr_o      = 1'b0;
      mem_read_o  = 1'b0;
      mem_write_o = 1'b0;
      rd_we_o     = 1'b0;
    end
  end

endmodule
