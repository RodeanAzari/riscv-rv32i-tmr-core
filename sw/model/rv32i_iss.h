/* RV32I golden model for the UVM environment (Phase C), optionally RV32IM
 * (rv_set_m): an instruction-set simulator, one instruction per call, no
 * pipeline and no timing.
 *
 * Written from the ISA specification, independently of the RTL and of the
 * Python model the cocotb tests use, so that it can disagree with both. It
 * follows this core's documented choices where RV32I leaves room
 * (docs/PROGRESS.md):
 *
 *   - Every exception halts: ECALL, EBREAK, an illegal instruction (any word
 *     that is not one of the 40 RV32I encodings, CSR accesses, MRET, WFI and
 *     FENCE.I included; the 8 M encodings too unless rv_set_m(1)), a load or store whose address is not a multiple of
 *     its size, and a taken branch or jump to a target that is not 4-byte
 *     aligned (JALR clears bit 0 first). A trapping instruction retires with
 *     trap = halt = 1, no register write and no memory access, and nothing
 *     after it executes.
 *   - FENCE is a NOP.
 *   - M, when on, follows the spec's table for the cases that do not trap:
 *     x / 0 gives DIV/DIVU all ones and REM/REMU the dividend; INT_MIN / -1
 *     gives DIV INT_MIN and REM 0.
 *
 * Each step fills an RVFI-shaped record, in the core's conventions: rs1/rs2
 * are the instruction's register fields whether it reads them or not; rd_addr
 * is 0 when no register is written (x0 included); memory fields are
 * lane-style (word address, byte masks, data in its lanes).
 *
 * The register file is not reset in the core, so the model tracks which
 * registers have been written since rv_reset; a comparison of a value read
 * from an unwritten register would compare against a guess.
 */
#ifndef RV32I_ISS_H
#define RV32I_ISS_H

#include <stdint.h>

#define RV_MEM_BYTES (1u << 20)     /* model memory: 1 MiB from address 0 */

enum rv_status {
    RV_OK          =  0,
    RV_HALTED      =  1,   /* this instruction trapped and the model halted */
    RV_BAD_ADDR    = -2,   /* fetch or access outside RV_MEM_BYTES          */
    RV_STOPPED     = -3,   /* stepped after a halt                          */
};

typedef struct {
    uint32_t insn, pc_rdata, pc_wdata;
    uint32_t rs1_addr, rs1_rdata, rs2_addr, rs2_rdata;
    uint32_t rs1_defined, rs2_defined;
    uint32_t rd_addr, rd_wdata;
    uint32_t mem_addr, mem_rmask, mem_wmask, mem_rdata, mem_wdata;
    uint32_t trap, halt;
} rv_rec_t;

void     rv_reset(uint32_t pc);                      /* registers undefined, memory kept */
void     rv_set_m(int on);                           /* RV32IM if on; off by default, kept across rv_reset */
void     rv_mem_clear(void);
void     rv_mem_write32(uint32_t addr, uint32_t word); /* addr word-aligned */
uint32_t rv_mem_read32(uint32_t addr);
uint32_t rv_reg(uint32_t r);
uint32_t rv_pc(void);
int      rv_step(rv_rec_t *rec);                     /* returns an rv_status */

#endif
