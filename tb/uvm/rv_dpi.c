/* DPI-C face of the golden model (sw/model/rv32i_iss.c) for the UVM
 * environment. Plain C types only, so the SystemVerilog imports in rv_pkg.sv
 * are int unsigned throughout.
 */
#include "../../sw/model/rv32i_iss.h"

void rvm_reset(unsigned pc) { rv_reset(pc); }
void rvm_mem_clear(void) { rv_mem_clear(); }
void rvm_mem_write(unsigned addr, unsigned word) { rv_mem_write32(addr, word); }

int rvm_step(unsigned *insn, unsigned *pc_rdata, unsigned *pc_wdata,
             unsigned *rs1_addr, unsigned *rs1_rdata, unsigned *rs1_defined,
             unsigned *rs2_addr, unsigned *rs2_rdata, unsigned *rs2_defined,
             unsigned *rd_addr, unsigned *rd_wdata,
             unsigned *mem_addr, unsigned *mem_rmask, unsigned *mem_wmask,
             unsigned *mem_rdata, unsigned *mem_wdata,
             unsigned *trap, unsigned *halt)
{
    rv_rec_t r;
    int s = rv_step(&r);
    *insn = r.insn; *pc_rdata = r.pc_rdata; *pc_wdata = r.pc_wdata;
    *rs1_addr = r.rs1_addr; *rs1_rdata = r.rs1_rdata; *rs1_defined = r.rs1_defined;
    *rs2_addr = r.rs2_addr; *rs2_rdata = r.rs2_rdata; *rs2_defined = r.rs2_defined;
    *rd_addr = r.rd_addr; *rd_wdata = r.rd_wdata;
    *mem_addr = r.mem_addr; *mem_rmask = r.mem_rmask; *mem_wmask = r.mem_wmask;
    *mem_rdata = r.mem_rdata; *mem_wdata = r.mem_wdata;
    *trap = r.trap; *halt = r.halt;
    return s;
}
