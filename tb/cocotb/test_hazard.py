"""Hazard unit: forwarding selects and load-use stall, swept exhaustively.

Register addresses drawn from {x0, x1, x2} are enough to produce every
relationship that matters -- equal, different, and x0 -- between every pair of
pipeline slots, so the sweep covers all of them: 3^7 address combinations x 2^3
control bits. The reference model below is written from the rules in CLAUDE.md
5.3, not read off the RTL.
"""

import itertools

import cocotb
from cocotb.triggers import Timer

REGS = (0, 1, 2)


def ref_forward(ex_rs, mem_rd, mem_we, wb_rd, wb_we):
    """(from EX/MEM, from MEM/WB) for one operand. Younger write wins; x0 never."""
    from_mem = bool(mem_we and mem_rd != 0 and mem_rd == ex_rs)
    from_wb = bool(wb_we and wb_rd != 0 and wb_rd == ex_rs and not from_mem)
    return from_mem, from_wb


def ref_stall(id_rs1, id_rs2, ex_rd, ex_load):
    return bool(ex_load and ex_rd != 0 and ex_rd in (id_rs1, id_rs2))


@cocotb.test()
async def test_exhaustive_against_reference(dut):
    checked = 0
    for (id_rs1, id_rs2, ex_rs1, ex_rs2, ex_rd, mem_rd, wb_rd) in \
            itertools.product(REGS, repeat=7):
        for ex_load, mem_we, wb_we in itertools.product((0, 1), repeat=3):
            dut.id_rs1_addr_i.value = id_rs1
            dut.id_rs2_addr_i.value = id_rs2
            dut.ex_rs1_addr_i.value = ex_rs1
            dut.ex_rs2_addr_i.value = ex_rs2
            dut.ex_rd_addr_i.value = ex_rd
            dut.ex_mem_read_i.value = ex_load
            dut.mem_rd_addr_i.value = mem_rd
            dut.mem_rd_we_i.value = mem_we
            dut.wb_rd_addr_i.value = wb_rd
            dut.wb_rd_we_i.value = wb_we
            await Timer(1, unit="ns")

            ctx = (f"id=({id_rs1},{id_rs2}) ex=({ex_rs1},{ex_rs2})->{ex_rd} "
                   f"load={ex_load} mem={mem_rd}/we{mem_we} wb={wb_rd}/we{wb_we}")
            want1 = ref_forward(ex_rs1, mem_rd, mem_we, wb_rd, wb_we)
            want2 = ref_forward(ex_rs2, mem_rd, mem_we, wb_rd, wb_we)
            got1 = (bool(dut.fwd_rs1_ex_mem_o.value), bool(dut.fwd_rs1_mem_wb_o.value))
            got2 = (bool(dut.fwd_rs2_ex_mem_o.value), bool(dut.fwd_rs2_mem_wb_o.value))
            assert got1 == want1, f"rs1 forward {got1}, expected {want1}: {ctx}"
            assert got2 == want2, f"rs2 forward {got2}, expected {want2}: {ctx}"
            want_stall = ref_stall(id_rs1, id_rs2, ex_rd, ex_load)
            assert bool(dut.stall_o.value) == want_stall, (
                f"stall {int(dut.stall_o.value)}, expected {int(want_stall)}: {ctx}"
            )
            checked += 1
    dut._log.info(f"{checked} input combinations checked")


@cocotb.test()
async def test_forward_selects_are_one_hot(dut):
    """Both sources matching must never select both -- the core's mux would
    then depend on its own if/else order rather than on this unit."""
    dut.id_rs1_addr_i.value = 0
    dut.id_rs2_addr_i.value = 0
    dut.ex_rd_addr_i.value = 0
    dut.ex_mem_read_i.value = 0
    dut.ex_rs1_addr_i.value = 3
    dut.ex_rs2_addr_i.value = 3
    dut.mem_rd_addr_i.value = 3
    dut.mem_rd_we_i.value = 1
    dut.wb_rd_addr_i.value = 3
    dut.wb_rd_we_i.value = 1
    await Timer(1, unit="ns")
    assert int(dut.fwd_rs1_ex_mem_o.value) == 1 and int(dut.fwd_rs1_mem_wb_o.value) == 0
    assert int(dut.fwd_rs2_ex_mem_o.value) == 1 and int(dut.fwd_rs2_mem_wb_o.value) == 0
