// RV32I instruction decode: register addresses and the immediate.
//
// Scope note: this decodes only what the ID slice consumes. The ALU operation,
// memory controls and writeback select are decoded when EX, MEM and WB exist
// to consume them -- a control signal with no destination is dead logic that
// lint cannot distinguish from a mistake.
//
// Register address fields sit at fixed positions in every RV32I format, so they
// are extracted unconditionally. Whether a given instruction actually *uses*
// rs1, rs2 or rd is a control question, answered in the EX slice. Reading a
// field that the instruction ignores is harmless here: nothing acts on it yet,
// and the register file has no side effects on read.
module riscv_decoder #(
    parameter int unsigned XLEN   = 32,
    parameter int unsigned ADDR_W = 5
) (
    input  logic [XLEN-1:0]   instr_i,

    output logic [ADDR_W-1:0] rs1_addr_o,
    output logic [ADDR_W-1:0] rs2_addr_o,
    output logic [ADDR_W-1:0] rd_addr_o,
    output logic [XLEN-1:0]   imm_o
);

  // RV32I major opcodes (CLAUDE.md §5.1)
  localparam logic [6:0] OPCODE_LUI    = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPCODE_JAL    = 7'b1101111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;
  localparam logic [6:0] OPCODE_STORE  = 7'b0100011;

  logic [6:0] opcode;
  assign opcode = instr_i[6:0];

  assign rs1_addr_o = instr_i[19:15];
  assign rs2_addr_o = instr_i[24:20];
  assign rd_addr_o  = instr_i[11:7];

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

endmodule
