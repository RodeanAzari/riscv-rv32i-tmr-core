# RISC-V RV32I core — single entry point. See CLAUDE.md §2 for the full list
# and the phase each target belongs to.
#
#   make lint   verilator lint of rtl/
#   make sim    cocotb regression on verilator (see tb/cocotb/Makefile)
#   make formal SymbiYosys over every tb/formal/*.sby, then riscv-formal
#   make sw     build sw/*.c to .elf and .hex
#   make spike  run the .elf on the spike reference model
#   make synth  out-of-context synth + impl of the core, reports to docs/reports
#   make fw     first-light firmware for the board SoC
#   make bench  CoreMark for the board SoC (board and simulation images)
#   make impl   board-level bitstream for the Arty A7;  make prog  program it
#   make model-test  the C golden model alone, on riscv-tests rv32ui
#   make uvm    UVM regression in XSim against the golden model
#   make clean
#
# asic exists as a stub that says which phase it belongs to, so a clean
# checkout gets a reason rather than "No rule to make target".

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
# Twice: once as synthesis sees the RTL, once with everything simulation and
# formal add -- RISCV_FORMAL (the RVFI port) and FORMAL (the property blocks).
# Code inside an `ifdef that is never defined is never linted at all, so a
# single run would leave both unchecked.
#
# Then the board top, which the core-only runs never elaborate. It
# instantiates Xilinx primitives (MMCME2_BASE, BUFG); tb/models/ has lint
# stand-ins for them, never read by Vivado.
XILINX_MODELS := $(shell find tb/models -name '*.sv' | sort)

.PHONY: lint
lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module $(TOP) -DRISCV_FORMAL -DFORMAL $(RTL)
	verilator --lint-only -Wall --top-module arty_a7_top $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall --top-module arty_a7_top -DRISCV_FORMAL -DFORMAL $(RTL) $(XILINX_MODELS)

# --- simulation ------------------------------------------------------------
.PHONY: sim
sim:
	$(MAKE) -C tb/cocotb

# --- formal ----------------------------------------------------------------
# Every tb/formal/*.sby, each with all its tasks (prove, cover). The tools come
# from OSS CAD Suite, whose bin/ is APPENDED to PATH here, never prepended: it
# ships its own Verilator and Python, which must not shadow the pinned ones
# (docs/PROGRESS.md, Toolchain). Doing it here rather than relying on
# ~/.bashrc also covers non-interactive shells, which never read it. CI puts
# the suite on PATH itself, where OSS_CAD_BIN simply does not exist.
#
# Then riscv-formal (CLAUDE.md 5.5, Phase B) via scripts/riscv-formal.sh: ISA
# compliance of every instruction through the RVFI port, plus the register,
# pc-chain, ordering and causality checks, and a cover pass proving none of
# them vacuous. FORMAL_JOBS parallel solver runs (default: every core).
#
# Like `make sim`, every job runs even after a failure, then the target fails
# if any did. Work directories land in tb/formal/build/.
OSS_CAD_BIN ?= $(HOME)/.local/opt/oss-cad-suite/bin
# -maxdepth 1: the riscv-formal submodule ships .sby files of its own.
SBY_FILES   := $(shell find tb/formal -maxdepth 1 -name '*.sby' 2>/dev/null | sort)
FORMAL_JOBS ?= $(shell nproc)

.PHONY: formal
formal:
	@if [ -z "$(SBY_FILES)" ]; then echo "no .sby files under tb/formal/" >&2; exit 1; fi
	@rc=0; \
	for f in $(SBY_FILES); do \
	  echo "=== $$f ==="; \
	  ( cd $$(dirname $$f) && PATH="$$PATH:$(OSS_CAD_BIN)" \
	      sby -f --prefix build/$$(basename $$f .sby) $$(basename $$f) ) || rc=1; \
	done; \
	PATH="$$PATH:$(OSS_CAD_BIN)" scripts/riscv-formal.sh . $(FORMAL_JOBS) || rc=1; \
	if [ $$rc -ne 0 ]; then echo "FORMAL FAILED"; fi; \
	exit $$rc

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

# First-light firmware for rtl/top/soc.sv (sw/firstlight/): a board image and
# a simulation image with a short delay loop, both as $readmemh hex for the
# RAM. The local riscv32 toolchain if present, else the riscv64 one CI
# installs -- -march/-mabi pick the target either way, and nothing is linked.
RISCV_PREFIX ?= $(if $(wildcard $(HOME)/riscv-toolchain/bin/riscv32-unknown-elf-gcc),$(HOME)/riscv-toolchain/bin/riscv32-unknown-elf-,riscv64-unknown-elf-)
FW_DIR    := sw/firstlight
FW_BUILD  := sw/build
FW_CFLAGS := -march=rv32i -mabi=ilp32 -O2 -Wall -Wextra -ffreestanding \
             -nostdlib -nostartfiles -static -T$(FW_DIR)/link.ld \
             -Wl,--no-warn-rwx-segments
FW_DEPS   := $(FW_DIR)/crt0.S $(FW_DIR)/link.ld

.PHONY: fw
fw: $(FW_BUILD)/hello.hex $(FW_BUILD)/hello_sim.hex

$(FW_BUILD)/hello.elf: $(FW_DIR)/hello.c $(FW_DEPS)
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(FW_CFLAGS) -o $@ $(FW_DIR)/crt0.S $<

$(FW_BUILD)/hello_sim.elf: $(FW_DIR)/hello.c $(FW_DEPS)
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(FW_CFLAGS) -DDELAY_LOOPS=20u -o $@ $(FW_DIR)/crt0.S $<

# CoreMark (sw/coremark, unmodified, as its run rules require) with this
# SoC's port (sw/coremark-port/). The board image runs COREMARK_ITERATIONS,
# enough for CoreMark's 10-second minimum at 50 MHz; the simulation image
# runs one iteration, which still validates every CRC. Unlike first light it
# links libgcc: RV32I has no multiply or divide, and CoreMark uses both.
COREMARK_ITERATIONS ?= 1000
BENCH_OPT    := -O2
BENCH_SRCS   := sw/coremark-port/core_portme.c \
                $(addprefix sw/coremark/,core_list_join.c core_main.c \
                  core_matrix.c core_state.c core_util.c)
BENCH_CFLAGS := $(filter-out -O2,$(FW_CFLAGS)) $(BENCH_OPT) \
                -Isw/coremark-port -Isw/coremark \
                '-DFLAGS_STR="$(BENCH_OPT) -march=rv32i -mabi=ilp32"'

.PHONY: bench
bench: $(FW_BUILD)/coremark.hex $(FW_BUILD)/coremark_sim.hex

$(FW_BUILD)/coremark.elf: $(BENCH_SRCS) sw/coremark-port/core_portme.h $(FW_DEPS)
	@test -f sw/coremark/core_main.c || { echo "sw/coremark is empty -- run: git submodule update --init sw/coremark" >&2; exit 1; }
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(BENCH_CFLAGS) -DITERATIONS=$(COREMARK_ITERATIONS) \
		-o $@ $(FW_DIR)/crt0.S $(BENCH_SRCS) -lgcc

$(FW_BUILD)/coremark_sim.elf: $(BENCH_SRCS) sw/coremark-port/core_portme.h $(FW_DEPS)
	@test -f sw/coremark/core_main.c || { echo "sw/coremark is empty -- run: git submodule update --init sw/coremark" >&2; exit 1; }
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(BENCH_CFLAGS) -DITERATIONS=1 \
		-o $@ $(FW_DIR)/crt0.S $(BENCH_SRCS) -lgcc

$(FW_BUILD)/%.hex: $(FW_BUILD)/%.elf scripts/bin2hex.py
	$(RISCV_PREFIX)objcopy -O binary $< $(FW_BUILD)/$*.bin
	python3 scripts/bin2hex.py $(FW_BUILD)/$*.bin $@

# --- golden model ----------------------------------------------------------
# The C golden model the UVM environment steps through DPI-C (sw/model/).
# Checked on its own first: every rv32ui test the cocotb suite runs, with the
# same two exclusions (tb/cocotb/test_riscv_tests.py says why), must pass on
# the model alone before it is trusted to judge the RTL.
MODEL_DIR   := sw/model
MODEL_BUILD := sw/build/model
RV32UI_SKIP := fence_i ma_data
RV32UI      := $(filter-out $(RV32UI_SKIP), \
                 $(basename $(notdir $(wildcard sw/riscv-tests/isa/rv32ui/*.S))))

.PHONY: model-test
model-test: $(MODEL_BUILD)/rv32ui_check $(RV32UI:%=$(MODEL_BUILD)/rv32ui/%.bin)
	$(MODEL_BUILD)/rv32ui_check $(RV32UI:%=$(MODEL_BUILD)/rv32ui/%.bin)

$(MODEL_BUILD)/rv32ui_check: $(MODEL_DIR)/rv32ui_check.c $(MODEL_DIR)/rv32i_iss.c $(MODEL_DIR)/rv32i_iss.h
	@mkdir -p $(@D)
	cc -std=c11 -O2 -Wall -Wextra -Werror -o $@ $(MODEL_DIR)/rv32ui_check.c $(MODEL_DIR)/rv32i_iss.c

$(MODEL_BUILD)/rv32ui/%.bin: sw/riscv-tests/isa/rv32ui/%.S
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc -march=rv32i -mabi=ilp32 -static -nostdlib -nostartfiles \
		-Isw/riscv-tests-env -Isw/riscv-tests/isa/macros/scalar \
		-Tsw/riscv-tests-env/link.ld -o $(@:.bin=.elf) $<
	$(RISCV_PREFIX)objcopy -O binary $(@:.bin=.elf) $@

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

# --- UVM -------------------------------------------------------------------
# The Phase C regression in XSim (tb/uvm/, docs/coverage-plan.md): random
# programs checked retirement by retirement against the C golden model, and
# fails below COV_MIN percent functional coverage.
#   make uvm SEED=7 PROGRAMS=300 COV_MIN=95
SEED     ?= 1
PROGRAMS ?= 300
COV_MIN  ?= 95

.PHONY: uvm
uvm:
	scripts/setup-vivado-env.sh bash tb/uvm/run.sh $(SEED) $(PROGRAMS) $(COV_MIN)

# --- board -----------------------------------------------------------------
# Board-level synthesis, place & route and bitstream for the Arty A7 (Phase D):
# rtl/top/arty_a7_top.sv with the first-light firmware in its RAM. See
# syn/impl_arty.tcl; reports land in docs/reports/*_board.*, the bitstream in
# syn/build/board/.
BIT := syn/build/board/arty_a7_top.bit

.PHONY: impl prog
# FW_IMAGE picks the program the bitstream's RAM holds: first light by
# default, or e.g. FW_IMAGE=sw/build/coremark.hex for the benchmark.
FW_IMAGE ?= $(FW_BUILD)/hello.hex

impl: $(FW_IMAGE)
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/impl_arty.tcl -tclargs $(PART) $(FW_IMAGE)

# Two routes, picked per session (docs/vivado-setup.md section 6). If the Arty
# is attached to WSL with usbipd-win (FTDI 0403:6010 visible here), program it
# with openFPGALoader; otherwise print the Windows Hardware Manager steps.
# Either way the configuration is volatile: it lasts until power-off.
ARTY_USB := 0403:6010

prog:
	@test -f $(BIT) || { echo "no bitstream: run make impl first" >&2; exit 1; }
	@if $(OSS_CAD_BIN)/lsusb 2>/dev/null | grep -q "^$(ARTY_USB) "; then \
	  $(OSS_CAD_BIN)/openFPGALoader -b arty_a7_100t $(BIT) && \
	  echo "UART: screen /dev/ttyUSB1 115200  (ls /dev/ttyUSB* if not 1; Ctrl-a k quits)"; \
	else \
	  echo "Arty not attached to WSL (usbipd attach --wsl --busid <id> on Windows)."; \
	  echo "Or program it from Windows, in Vivado Lab Edition (Hardware Manager):"; \
	  echo "  1. Open Hardware Manager > Open Target > Auto Connect"; \
	  echo "  2. Right-click xc7a100t_0 > Program Device, bitstream:"; \
	  printf '     %s\n' "$$(wslpath -w $(abspath $(BIT)))"; \
	  echo "  3. Serial terminal on the board's COM port: 115200 baud, 8N1"; \
	  echo "  4. Press the red RESET button to restart the program"; \
	fi

# --- not yet built ---------------------------------------------------------
# Each names its phase and what it is waiting on. Fail loudly, not silently.
.PHONY: asic

asic:
	@echo "make asic: LibreLane RTL-to-GDSII (CLAUDE.md §6.4). Run #1 closes" >&2
	@echo "           Phase E on the non-TMR core, run #2 the full SoC in Phase H." >&2
	@echo "           Needs LibreLane + Sky130 (not installed)." >&2
	@exit 1


# --- housekeeping ----------------------------------------------------------
.PHONY: clean
clean:
	$(MAKE) -C tb/cocotb clean
	rm -rf obj_dir tb/cocotb/dump.vcd tb/formal/build
	rm -f sw/prog.elf sw/prog.hex
	rm -rf syn/build .Xil
	rm -f vivado*.log vivado*.jou
