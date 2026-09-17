// RV32I ALU.
//
// The operation selector is the ISA's own encoding -- funct3 plus the "alt" bit
// that distinguishes ADD from SUB and SRL from SRA -- rather than a private
// enum shared with the decoder. Two reasons: there is no second copy of an
// encoding to drift out of step, and it avoids a SystemVerilog package, which
// CLAUDE.md §4 flags as a Yosys-compatibility risk that cannot be checked until
// SymbiYosys is installed in Phase B.
//
// Where alt_i comes from is the decoder's problem, and it is not the same bit
// for every instruction:
//
//   OP (register-register)  alt = instr[30] (funct7[5]) for ADD/SUB and SRL/SRA
//   OP-IMM shifts           alt = instr[30], which is part of the shamt field's
//                           funct7 and is architecturally defined there
//   OP-IMM non-shifts       alt = 0, ALWAYS. instr[30] is an immediate bit, not
//                           a mode bit. See the decoder for why this matters.
module riscv_alu #(
    parameter int unsigned XLEN = 32
) (
    input  logic [XLEN-1:0] a_i,
    input  logic [XLEN-1:0] b_i,
    input  logic [2:0]      funct3_i,
    input  logic            alt_i,
    output logic [XLEN-1:0] result_o
);

  // RV32I funct3 encodings for OP / OP-IMM
  localparam logic [2:0] F3_ADD_SUB = 3'b000;
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // Shifts use only the low 5 bits of the operand. RV32I defines this for both
  // register shifts (rs2[4:0]) and immediate shifts (shamt), so the upper bits
  // are ignored rather than being an error.
  logic [4:0] shamt;
  assign shamt = b_i[4:0];

  always_comb begin
    case (funct3_i)
      F3_ADD_SUB: result_o = alt_i ? (a_i - b_i) : (a_i + b_i);
      F3_SLL:     result_o = a_i << shamt;
      F3_SLT:     result_o = {{(XLEN-1){1'b0}}, ($signed(a_i) < $signed(b_i))};
      F3_SLTU:    result_o = {{(XLEN-1){1'b0}}, (a_i < b_i)};
      F3_XOR:     result_o = a_i ^ b_i;
      // >>> on an unsigned operand is a logical shift, so SRA needs the operand
      // cast signed. Getting this wrong is invisible until a negative value is
      // shifted, which small random test values rarely produce.
      F3_SRL_SRA: result_o = alt_i ? $unsigned($signed(a_i) >>> shamt)
                                   : (a_i >> shamt);
      F3_OR:      result_o = a_i | b_i;
      F3_AND:     result_o = a_i & b_i;
      default:    result_o = '0;
    endcase
  end

endmodule
