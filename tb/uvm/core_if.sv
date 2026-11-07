// Everything the UVM environment sees of riscv_core: its memory ports, RVFI,
// and a few internal signals the coverage plan needs that RVFI cannot show
// (docs/coverage-plan.md, "white-box"). tb_top.sv drives the probes.
interface core_if (input logic clk);
  logic        rst;

  // memory ports
  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_we;
  logic        halt;

  // RVFI
  logic        rvfi_valid;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_pc_rdata, rvfi_pc_wdata;
  logic        rvfi_trap, rvfi_halt, rvfi_intr;
  logic [4:0]  rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [31:0] rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [31:0] rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [3:0]  rvfi_mem_rmask, rvfi_mem_wmask;

  // white-box probes (read-only)
  logic        id_ex_valid, if_id_valid;
  logic        fwd_rs1_ex_mem, fwd_rs1_mem_wb, fwd_rs2_ex_mem, fwd_rs2_mem_wb;
  logic        stall, redirect;
  logic        mstall;                   // an M instruction waits in EX (M_EXT)
  logic [31:0] if_id_instr, id_ex_instr, mem_wb_instr;
  logic [4:0]  ex_mem_rd_addr, wb_rd_addr;
  logic        ex_mem_rd_we, wb_rd_we;
  logic        bypass_rs1, bypass_rs2;   // the instruction now in EX read its
                                         // operand through the WB->ID bypass
endinterface
