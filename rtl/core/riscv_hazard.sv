// Hazard unit: operand forwarding selects for EX, and load-use stall detection
// for ID. Purely combinational; it decides, the core's muxes and pipeline
// registers act.
//
// Forwarding (CLAUDE.md 5.3). An instruction in EX may read a register that an
// older instruction, still in the pipeline, has computed but not yet written:
//
//   from EX/MEM -- the instruction one ahead. Spec name "EX->EX": its ALU
//                  result was produced in EX last cycle.
//   from MEM/WB -- two ahead. Spec name "MEM->EX". Covers loads too: load data
//                  arrives in WB, so this is the path a load result takes.
//   three ahead -- writing the register file this cycle while the consumer is
//                  in ID; the register file's write-first bypass handles it
//                  ("WB->ID"), so it never needs a mux here.
//
// When both EX/MEM and MEM/WB match, EX/MEM wins: it is the younger write,
// and the one program order says the consumer should see. Each operand is
// checked independently, so rs1 and rs2 naming the same register both forward
// (a 9 failure mode).
//
// Writes to x0 are never forwarded. The register file discards them, so x0
// reads zero -- but a forwarding path that matched on rd = 0 would hand the
// discarded value straight to the consumer.
//
// Load-use. A load's data is not available until WB, so an instruction
// directly behind a load cannot get it from EX/MEM in time. ID detects the pair
// and stalls one cycle: the pc and IF/ID hold, and a bubble enters ID/EX. Next
// cycle the load is in MEM/WB, and the consumer, now in EX, takes it from
// there. Because of the stall, the EX/MEM path never has to forward from a
// load -- whatever sits in EX/MEM's ALU result is a load's address, not its
// data. That is a formal property for Phase B.
//
// The stall is conservative: it compares the rs1/rs2 FIELDS, whether or not
// the instruction in ID actually reads them -- lui's "rs1" field is immediate
// bits. A false match costs one cycle, never correctness, and avoids a
// "uses rs1/rs2" decode for every opcode.
//
// Outputs are one-hot per operand, priority already resolved, rather than an
// encoded select -- so there is no second copy of an encoding in the core to
// drift out of step with this one.
module riscv_hazard #(
    parameter int unsigned ADDR_W = 5
) (
    // ID: the instruction being decoded (in IF/ID)
    input  logic [ADDR_W-1:0] id_rs1_addr_i,
    input  logic [ADDR_W-1:0] id_rs2_addr_i,

    // EX: the instruction in ID/EX
    input  logic [ADDR_W-1:0] ex_rs1_addr_i,
    input  logic [ADDR_W-1:0] ex_rs2_addr_i,
    input  logic [ADDR_W-1:0] ex_rd_addr_i,
    input  logic              ex_mem_read_i,

    // MEM: the instruction in EX/MEM
    input  logic [ADDR_W-1:0] mem_rd_addr_i,
    input  logic              mem_rd_we_i,

    // WB: the instruction in MEM/WB
    input  logic [ADDR_W-1:0] wb_rd_addr_i,
    input  logic              wb_rd_we_i,

    output logic              fwd_rs1_ex_mem_o,
    output logic              fwd_rs1_mem_wb_o,
    output logic              fwd_rs2_ex_mem_o,
    output logic              fwd_rs2_mem_wb_o,
    output logic              stall_o
);

  logic mem_writes, wb_writes;
  assign mem_writes = mem_rd_we_i && (mem_rd_addr_i != '0);
  assign wb_writes  = wb_rd_we_i  && (wb_rd_addr_i  != '0);

  assign fwd_rs1_ex_mem_o = mem_writes && (mem_rd_addr_i == ex_rs1_addr_i);
  assign fwd_rs1_mem_wb_o = wb_writes  && (wb_rd_addr_i  == ex_rs1_addr_i)
                            && !fwd_rs1_ex_mem_o;
  assign fwd_rs2_ex_mem_o = mem_writes && (mem_rd_addr_i == ex_rs2_addr_i);
  assign fwd_rs2_mem_wb_o = wb_writes  && (wb_rd_addr_i  == ex_rs2_addr_i)
                            && !fwd_rs2_ex_mem_o;

  // A load always writes rd, so ex_mem_read_i alone says "EX will write rd" --
  // except for a load to x0, which writes nothing and needs no stall.
  assign stall_o = ex_mem_read_i && (ex_rd_addr_i != '0)
                   && ((ex_rd_addr_i == id_rs1_addr_i)
                       || (ex_rd_addr_i == id_rs2_addr_i));

endmodule
