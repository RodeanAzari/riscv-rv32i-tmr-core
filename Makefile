# RISC-V RV32I core — single entry point. See CLAUDE.md §2 for the full list
# and the phase each target belongs to.
#
#   make lint   verilator lint of rtl/
#   make sim    cocotb regression on verilator (see tb/cocotb/Makefile)
#   make sw     build sw/*.c to .elf and .hex
#   make spike  run the .elf on the spike reference model
#   make synth  out-of-context synth + impl of the core, reports to docs/reports
#   make clean
#
# formal / uvm / asic / impl / prog exist as stubs that say which phase they
# belong to, so a clean checkout gets a reason rather than "No rule to make
# target". They become real in the phase they name.

XLEN_GCC := $(HOME)/riscv-toolchain/bin/riscv32-unknown-elf-gcc
ELF2HEX  := $(HOME)/riscv-toolchain/bin/elf2hex
SPIKE    := $(HOME)/riscv-toolchain/bin/spike

export TOP ?= riscv_core

# Recursive: rtl/ is nested (core/, tmr/, accel/, bus/, periph/ as they appear),
# so a one-level rtl/*.sv glob would silently miss whole subdirectories. sorted
# because find returns filesystem order, which differs between machines and
# would make CI and local builds disagree on compile order.
RTL := $(shell find rtl -name '*.sv' | sort)

ifeq ($(RTL),)
  $(error no .sv files found under rtl/)
endif

# --- lint ------------------------------------------------------------------
# No --timing: that flag is for delay and event constructs, which CLAUDE.md §3
# forbids in rtl/. If lint ever needs it, something non-synthesizable got in.
#
# Twice: once as synthesis sees the RTL, once with RISCV_FORMAL as simulation
# and formal see it. Code inside an `ifdef that is never defined is never
# linted at all, so a single run would leave the RVFI logic unchecked.
.PHONY: lint
lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module $(TOP) -DRISCV_FORMAL $(RTL)

# --- simulation ------------------------------------------------------------
.PHONY: sim
sim:
	$(MAKE) -C tb/cocotb

# --- software --------------------------------------------------------------
CFLAGS_RV := -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -O2 -Tsw/link.ld
SW_SRCS   := $(shell find sw -name '*.c' 2>/dev/null | sort)

.PHONY: sw
sw: sw/prog.hex

sw/prog.elf: $(SW_SRCS) sw/link.ld
	$(XLEN_GCC) $(CFLAGS_RV) -o $@ $(SW_SRCS)

sw/prog.hex: sw/prog.elf
	$(ELF2HEX) --bit-width 32 --input $< --output $@

.PHONY: spike
spike: sw/prog.elf
	$(SPIKE) --isa=rv32i $<

# --- synthesis -------------------------------------------------------------
# Out-of-context: the core alone, no board-level top yet. See syn/synth_ooc.tcl
# for why, and docs/vivado-setup.md for the environment the wrapper sets up.
#
# This runs through route_design, not just synth_design: post-synthesis timing
# is an estimate, post-route timing is measured. CLAUDE.md §2 splits synth from
# impl, and impl is the board-level bitstream flow in Phase D.
PART   ?= xc7a100tcsg324-1
VIVADO := scripts/setup-vivado-env.sh vivado

.PHONY: synth
synth:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART)

# --- not yet built ---------------------------------------------------------
# Each names its phase and what it is waiting on. Fail loudly, not silently.
.PHONY: formal uvm asic impl prog

formal:
	@echo "make formal: Phase B. Needs SymbiYosys + yosys (not installed);" >&2
	@echo "             properties live in tb/formal/ once written." >&2
	@exit 1

uvm:
	@echo "make uvm: Phase C. Needs the UVM environment in tb/uvm/, run in XSim." >&2
	@exit 1

asic:
	@echo "make asic: OpenLane RTL-to-GDSII (CLAUDE.md §6.4). Run #1 closes" >&2
	@echo "           Phase E on the non-TMR core, run #2 the full SoC in Phase H." >&2
	@echo "           Needs OpenLane + Sky130 (not installed)." >&2
	@exit 1

impl:
	@echo "make impl: Phase D. Board-level place & route and bitstream; needs" >&2
	@echo "           constr/arty_a7.xdc and a board top, neither of which exists." >&2
	@echo "           For core-only numbers today, use: make synth" >&2
	@exit 1

prog:
	@echo "make prog: Phase D. Blocked on WSL2 USB passthrough for JTAG --" >&2
	@echo "           see docs/vivado-setup.md section 6." >&2
	@exit 1

# --- housekeeping ----------------------------------------------------------
.PHONY: clean
clean:
	$(MAKE) -C tb/cocotb clean
	rm -rf obj_dir tb/cocotb/dump.vcd
	rm -f sw/prog.elf sw/prog.hex
	rm -rf syn/build .Xil
	rm -f vivado*.log vivado*.jou
