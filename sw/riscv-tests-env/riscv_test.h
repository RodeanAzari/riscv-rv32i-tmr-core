// riscv-tests environment for this core: bare RV32I, no CSRs, no traps.
//
// Replaces riscv-tests' env/p/riscv_test.h, which this core cannot run: its
// startup writes mtvec, mstatus, satp and the PMP CSRs and enters the test
// through mret, and its pass/fail reporting is a trap handler. None of that
// exists here (CLAUDE.md 5.1). The test bodies and test_macros.h are used
// unmodified -- only the frame around them changes.
//
// The contract with the testbench (tb/cocotb/test_riscv_tests.py):
//   - _start is at address 0, the reset vector (see link.ld).
//   - The test ends in ECALL, which halts this core. gp (TESTNUM) then holds
//     1 for a pass, or (n << 1) | 1 where n is the first failing test case.
// PASS and FAIL are the official macros verbatim; on a core with traps the
// handler would read gp, here the testbench does.

#ifndef _ENV_RV32I_HALT_H
#define _ENV_RV32I_HALT_H

// The rv32ui sources redefine RVTEST_RV64U as RVTEST_RV32U, so both exist.
// Neither needs to do anything: there is no XLEN or extension to configure.
#define RVTEST_RV32U
#define RVTEST_RV64U RVTEST_RV32U

#define TESTNUM gp

// x1-x31 are zeroed first. The register file has no reset, and the official
// environment zeroes them too, so a test that leans on a register it never
// wrote sees the same 0 here as it would there.
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;                      \
        li x5, 0;  li x6, 0;  li x7, 0;  li x8, 0;                      \
        li x9, 0;  li x10, 0; li x11, 0; li x12, 0;                     \
        li x13, 0; li x14, 0; li x15, 0; li x16, 0;                     \
        li x17, 0; li x18, 0; li x19, 0; li x20, 0;                     \
        li x21, 0; li x22, 0; li x23, 0; li x24, 0;                     \
        li x25, 0; li x26, 0; li x27, 0; li x28, 0;                     \
        li x29, 0; li x30, 0; li x31, 0;

// Unreachable: every test ends in PASS or FAIL. If one ever falls through,
// unimp assembles to csrrw x0, cycle, x0 (0xc0001073), a CSR access: an
// illegal instruction here, so the core halts without the pass ECALL.
#define RVTEST_CODE_END                                                 \
        unimp

#define RVTEST_PASS                                                     \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        li a7, 93;                                                      \
        li a0, 0;                                                       \
        ecall

// The beqz loop is upstream's: a failure with TESTNUM still 0 means the
// failure came from the environment, not a test case, and it spins rather
// than report a misleading pass-like value.
#define RVTEST_FAIL                                                     \
        fence;                                                          \
1:      beqz TESTNUM, 1b;                                               \
        sll TESTNUM, TESTNUM, 1;                                        \
        or TESTNUM, TESTNUM, 1;                                         \
        li a7, 93;                                                      \
        addi a0, TESTNUM, 0;                                            \
        ecall

#define RVTEST_DATA_BEGIN                                               \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
