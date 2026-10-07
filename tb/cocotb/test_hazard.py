"""Hazard unit: forwarding selects and load-use stall, swept exhaustively.

Everything is compared against the instruction in ID: the producers are ID/EX
(in EX/MEM by the time the consumer reaches EX) and EX/MEM (in MEM/WB by
then). Register addresses drawn from {x0, x1, x2, x3} produce every
relationship that matters -- equal, different, and x0 -- between every pair,
so the sweep covers all of them: 4^4 address combinations x 2^3 control bits.
The reference model below is written from the rules in CLAUDE.md 5.3, not
read off the RTL.
"""

import itertools

import cocotb
from cocotb.triggers import Timer

REGS = (0, 1, 2, 3)


def ref_forward(id_rs, ex_rd, ex_we, mem_rd, mem_we):
    """(from EX/MEM, from MEM/WB) for one operand, for its cycle in EX.

    ID/EX's instruction will be the one in EX/MEM then, so it is the younger
    write and wins; x0 is never forwarded."""
    from_ex_mem = bool(ex_we and ex_rd != 0 and ex_rd == id_rs)
    from_mem_wb = bool(mem_we and mem_rd != 0 and mem_rd == id_rs and not from_ex_mem)
    return from_ex_mem, from_mem_wb


def ref_stall(id_rs1, id_rs2, ex_rd, ex_load):
    return bool(ex_load and ex_rd != 0 and ex_rd in (id_rs1, id_rs2))


@cocotb.test()
async def test_exhaustive_against_reference(dut):
    checked = 0
    for (id_rs1, id_rs2, ex_rd, mem_rd) in itertools.product(REGS, repeat=4):
        for ex_we, ex_load, mem_we in itertools.product((0, 1), repeat=3):
            dut.id_rs1_addr_i.value = id_rs1
            dut.id_rs2_addr_i.value = id_rs2
            dut.ex_rd_addr_i.value = ex_rd
            dut.ex_rd_we_i.value = ex_we
            dut.ex_mem_read_i.value = ex_load
            dut.mem_rd_addr_i.value = mem_rd
            dut.mem_rd_we_i.value = mem_we
            await Timer(1, unit="ns")

            ctx = (f"id=({id_rs1},{id_rs2}) ex={ex_rd}/we{ex_we}/load{ex_load} "
                   f"mem={mem_rd}/we{mem_we}")
            want1 = ref_forward(id_rs1, ex_rd, ex_we, mem_rd, mem_we)
            want2 = ref_forward(id_rs2, ex_rd, ex_we, mem_rd, mem_we)
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
    dut.id_rs1_addr_i.value = 3
    dut.id_rs2_addr_i.value = 3
    dut.ex_rd_addr_i.value = 3
    dut.ex_rd_we_i.value = 1
    dut.ex_mem_read_i.value = 0
    dut.mem_rd_addr_i.value = 3
    dut.mem_rd_we_i.value = 1
    await Timer(1, unit="ns")
    assert int(dut.fwd_rs1_ex_mem_o.value) == 1 and int(dut.fwd_rs1_mem_wb_o.value) == 0
    assert int(dut.fwd_rs2_ex_mem_o.value) == 1 and int(dut.fwd_rs2_mem_wb_o.value) == 0
