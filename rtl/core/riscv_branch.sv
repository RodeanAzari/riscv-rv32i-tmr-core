// Branch condition: does a conditional branch with this funct3 take, given its
// two (already forwarded) operands? Purely combinational. Whether the
// instruction in EX is a branch at all is the core's question, not this one's.
//
// The funct3 encoding has structure, and the logic follows it:
//
//   funct3[2:1]  00 = equal   10 = less than   11 = less than, unsigned
//   funct3[0]    negates      BEQ/BNE, BLT/BGE, BLTU/BGEU
//
// 010 and 011 are reserved. They decode to "never taken" -- defined rather than
// left to the synthesis tool, and the same answer a NOP would give.
//
// One magnitude comparison serves both orders. When the sign bits agree, signed
// and unsigned order are the same; when they differ, the operand with its sign
// bit set is the negative one, and so the smaller. That is a single carry chain
// plus one LUT, rather than two 32-bit comparators.
module riscv_branch #(
    parameter int unsigned XLEN = 32
) (
    input  logic [XLEN-1:0] a_i,       // rs1
    input  logic [XLEN-1:0] b_i,       // rs2
    input  logic [2:0]      funct3_i,
    output logic            cond_o
);

  localparam logic [1:0] CMP_EQ  = 2'b00;
  localparam logic [1:0] CMP_LT  = 2'b10;
  localparam logic [1:0] CMP_LTU = 2'b11;

  logic eq, lt, ltu;
  assign eq  = (a_i == b_i);
  assign ltu = (a_i < b_i);
  assign lt  = (a_i[XLEN-1] != b_i[XLEN-1]) ? a_i[XLEN-1] : ltu;

  always_comb begin
    case (funct3_i[2:1])
      CMP_EQ:  cond_o = eq  ^ funct3_i[0];
      CMP_LT:  cond_o = lt  ^ funct3_i[0];
      CMP_LTU: cond_o = ltu ^ funct3_i[0];
      default: cond_o = 1'b0;              // 010, 011: reserved
    endcase
  end

endmodule
