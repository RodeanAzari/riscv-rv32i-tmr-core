# RISC-V RV32I core — single entry point. See CLAUDE.md §2 for the full list
# and the phase each target belongs to.
#
#   make lint   verilator lint of rtl/
#   make sim    the GEMM golden model's self-check, then the cocotb
#               regression on verilator (see tb/cocotb/Makefile)
#   make formal SymbiYosys over every tb/formal/*.sby, then riscv-formal
#   make sw     build sw/*.c to .elf and .hex
#   make spike  run the .elf on the spike reference model
#   make synth  out-of-context synth + impl of the core, reports to docs/reports
#   make fw     first-light firmware for the board SoC
#   make bench  CoreMark for the board SoC (board and simulation images)
#   make impl   board-level bitstream for the Arty A7;  make prog  program it
#   make ila    program an ILA=1 build and capture the pipeline registers
#   make model-test  the golden models alone: C on riscv-tests rv32ui and
#                    rv32um, C and Python M against spike's vectors
#   make gemm-model  the systolic array's golden model alone (Phase F)
#   make dma-model   the DMA engine's golden model alone (Phase G)
#   make accel-model the GEMM accelerator's golden model alone (Phase G)
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
# DMA-Engine's register package (submodule, generated from its
# spec/dmaeng.yaml) comes first: packages compile before what imports them.
DMAENG_PKG := sw/dma-engine/rtl/dmaeng_pkg.sv
RTL := $(DMAENG_PKG) $(shell find rtl -name '*.sv' | sort)

ifeq ($(filter-out $(DMAENG_PKG),$(RTL)),)
  $(error no .sv files found under rtl/)
endif

# --- lint ------------------------------------------------------------------
# tb/lint/waivers.vlt: one waiver, for the generated DMA package (see there).
LINT_WAIVERS := tb/lint/waivers.vlt
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
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module $(TOP) -DRISCV_FORMAL -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top -DRISCV_FORMAL -DFORMAL $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top -GARRAY_CDC=1 $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top -GARRAY_CDC=1 -GTMR=1 -GM_EXT=1 -DRISCV_FORMAL -DFORMAL $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top -GM_EXT=1 -GRAM_WORDS=98304 $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top -GEXT_EN=1 $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module arty_a7_top -GEXT_EN=1 -GTMR=1 -DRISCV_FORMAL -DFORMAL $(RTL) $(XILINX_MODELS)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_core_tmr $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_core_tmr -DRISCV_FORMAL -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_core -GMEM_WAIT=1 $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_core -GMEM_WAIT=1 -DRISCV_FORMAL -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_core_tmr -GMEM_WAIT=1 -DRISCV_FORMAL -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_muldiv $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_muldiv -DFORMAL -DMULDIV_ARITH $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module riscv_muldiv -GXLEN=8 -DFORMAL -DMULDIV_ARITH $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module systolic_pe $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module systolic_array $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module systolic_pe_pair $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module dmaeng_regs $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module dmaeng $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module gemm_accel $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module gemm_accel -GROWS=4 -GCOLS=4 -GBUF_BYTES=2048 $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module gemm_accel -GARRAY_CDC=1 $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module gemm_accel -GARRAY_CDC=1 -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module gemm_accel -GARRAY_CDC=1 -GROWS=4 -GCOLS=4 -GBUF_BYTES=2048 -GARRAY_IN_DEPTH=2 -GARRAY_OUT_DEPTH=4 -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module axi_xbar -GN=3 -GM=2 $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module axi_xbar -GN=3 -GM=2 -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module cdc_async_fifo $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module cdc_async_fifo -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module cdc_async_fifo -GDEPTH=2 -GSYNC_STAGES=3 -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module cdc_pulse $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module cdc_pulse -DFORMAL $(RTL)
	verilator --lint-only -Wall $(LINT_WAIVERS) --top-module cdc_reset_sync $(RTL)

# --- simulation ------------------------------------------------------------
.PHONY: sim
sim: gemm-model dma-model accel-model llm-model llm-host
	$(MAKE) -C tb/cocotb

# The systolic array's golden model (sw/model/gemm_model.py) checks itself
# against plain integers and exact fractions before it judges any RTL. NumPy
# comes from the cocotb venv when there is one, as in tb/cocotb/Makefile; CI
# installs it with cocotb (tb/cocotb/requirements.txt).
GEMM_PY := $(if $(wildcard $(HOME)/cocotb-env/bin/python),$(HOME)/cocotb-env/bin/python,python3)

.PHONY: gemm-model
gemm-model:
	$(GEMM_PY) sw/model/gemm_model.py

# The GEMM accelerator's golden model (sw/model/accel_model.py): buffer
# layouts, registers, tiling, refused shapes and cycle count around
# gemm_model's arithmetic, checked against gemm() on the unpacked matrices.
# Then the same with the array on its own clock (sw/model/accel_cdc_model.py,
# Phase H): CYCLES edge by edge, C from the stream it schedules; and the
# array MMCM's DRP (sw/model/mmcm_drp.py, box 4).
.PHONY: accel-model
accel-model:
	$(GEMM_PY) sw/model/accel_model.py
	$(GEMM_PY) sw/model/accel_cdc_model.py
	$(GEMM_PY) sw/model/mmcm_drp.py

# The DMA engine's golden model (sw/model/dmaeng_model.py, ported from
# DMA-Engine's QEMU device) replays DMA-Engine's golden trace and runs the
# directed checks the trace does not cover. First, the register package and
# header it and the RTL read must be what DMA-Engine's spec/dmaeng.yaml
# generates (scripts/dmaeng_regs_check.py; needs PyYAML, pinned in
# tb/cocotb/requirements.txt).
.PHONY: dma-model
dma-model:
	python3 scripts/dmaeng_regs_check.py
	python3 sw/model/dmaeng_model.py

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
# about 21 s at 100 MHz: over CoreMark's 10-second minimum, under the 43 s
# the 32-bit cycle counter takes to wrap; the simulation image
# runs one iteration, which still validates every CRC. Unlike first light it
# links libgcc: RV32I has no multiply or divide, and CoreMark uses both.
COREMARK_ITERATIONS ?= 2000
BENCH_OPT    := -O2
BENCH_SRCS   := sw/coremark-port/core_portme.c \
                $(addprefix sw/coremark/,core_list_join.c core_main.c \
                  core_matrix.c core_state.c core_util.c)
BENCH_CFLAGS := $(filter-out -O2,$(FW_CFLAGS)) $(BENCH_OPT) \
                -Isw/coremark-port -Isw/coremark \
                '-DFLAGS_STR="$(BENCH_OPT) -march=rv32i -mabi=ilp32"'

# coremark_m{,_sim}: the same for the RV32IM core (Phase H, M_EXT), compiled
# -march=rv32im: multiply and divide inline, libgcc only for what remains.
# 2.6x faster per iteration, so 5000 iterations for the same ~20 s.
COREMARK_M_ITERATIONS ?= 5000
BENCH_M_CFLAGS := $(subst -march=rv32i ,-march=rv32im ,$(BENCH_CFLAGS))

.PHONY: bench
bench: $(FW_BUILD)/coremark.hex $(FW_BUILD)/coremark_sim.hex \
       $(FW_BUILD)/coremark_m.hex $(FW_BUILD)/coremark_m_sim.hex

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

$(FW_BUILD)/coremark_m.elf: $(BENCH_SRCS) sw/coremark-port/core_portme.h $(FW_DEPS)
	@test -f sw/coremark/core_main.c || { echo "sw/coremark is empty -- run: git submodule update --init sw/coremark" >&2; exit 1; }
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(BENCH_M_CFLAGS) -DITERATIONS=$(COREMARK_M_ITERATIONS) \
		-o $@ $(FW_DIR)/crt0.S $(BENCH_SRCS) -lgcc

$(FW_BUILD)/coremark_m_sim.elf: $(BENCH_SRCS) sw/coremark-port/core_portme.h $(FW_DEPS)
	@test -f sw/coremark/core_main.c || { echo "sw/coremark is empty -- run: git submodule update --init sw/coremark" >&2; exit 1; }
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(BENCH_M_CFLAGS) -DITERATIONS=1 \
		-o $@ $(FW_DIR)/crt0.S $(BENCH_SRCS) -lgcc

# The serial bootloader (sw/boot/), the default bitstream image since the
# UART gained a receiver: it receives programs from scripts/load.py and runs
# them, so changing the program needs no Vivado rebuild. No libgcc.
BOOT_CFLAGS := -march=rv32i -mabi=ilp32 -Os -Wall -Wextra -ffreestanding \
               -nostdlib -nostartfiles -static -Tsw/boot/link.ld -Isw/lib \
               -Wl,--no-warn-rwx-segments

.PHONY: boot
boot: $(FW_BUILD)/boot.hex

$(FW_BUILD)/boot.elf: sw/boot/boot.c sw/boot/crt0.S sw/boot/link.ld sw/lib/soc.h
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(BOOT_CFLAGS) -o $@ sw/boot/crt0.S sw/boot/boot.c

# Programs for the bootloader (sw/apps/*.c), linked at 0x1000 with the
# console library (sw/lib/) and libgcc, as flat binaries for scripts/load.py:
#   make apps && scripts/load.py sw/build/apps/echo.bin --term
APPS       := $(basename $(notdir $(wildcard sw/apps/*.c)))
APP_CFLAGS := $(filter-out -T$(FW_DIR)/link.ld,$(FW_CFLAGS)) -Tsw/app/link.ld -Isw/lib
APP_DEPS   := sw/app/crt0.S sw/app/link.ld sw/lib/io.c sw/lib/io.h sw/lib/soc.h

.PHONY: apps
apps: $(APPS:%=$(FW_BUILD)/apps/%.bin)

$(FW_BUILD)/apps/%.elf: sw/apps/%.c $(APP_DEPS)
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc $(APP_CFLAGS) -o $@ sw/app/crt0.S sw/lib/io.c $< -lgcc

# The demo reel (sw/demo/): one program of several files, so its own rule.
# -Os: at -O2 its code and the 12 KiB scratch buffer overflow the 28 KiB
# program area. The microbenchmarks are assembly, unaffected; the other
# demos' cycle counts are for -Os code.
DEMO_SRCS := $(wildcard sw/demo/*.c)

$(FW_BUILD)/apps/demo.elf: $(DEMO_SRCS) sw/demo/demo.h $(APP_DEPS)
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc $(filter-out -O2,$(APP_CFLAGS)) -Os -Isw/demo -o $@ sw/app/crt0.S sw/lib/io.c $(DEMO_SRCS) -lgcc

apps: $(FW_BUILD)/apps/demo.bin $(FW_BUILD)/boot_demo_sim.hex

# The DMA self-test (sw/apps/dmatest.c) with the bare-metal driver
# (sw/lib/dma.c) on DMA-Engine's generated header, read from the submodule.
DMA_INC := sw/dma-engine/include

$(FW_BUILD)/apps/dmatest.elf: sw/apps/dmatest.c sw/lib/dma.c sw/lib/dma.h $(DMA_INC)/dmaeng_regs.h $(APP_DEPS)
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc $(APP_CFLAGS) -I$(DMA_INC) -o $@ sw/app/crt0.S sw/lib/io.c sw/lib/dma.c $< -lgcc

apps: $(FW_BUILD)/boot_dma_sim.hex

# For simulation (tb/cocotb/test_dma.py): the bootloader with the DMA
# self-test saved, reached with r.
$(FW_BUILD)/boot_dma_sim.hex: $(FW_BUILD)/boot.hex $(FW_BUILD)/apps/dmatest.bin scripts/mkimage.py
	python3 scripts/mkimage.py $(FW_BUILD)/boot.bin $(FW_BUILD)/apps/dmatest.bin $@

# For simulation (tb/cocotb/test_ext.py): the bootloader with the external
# window's self-test (sw/apps/exttest.c; soc EXT_EN, fpga-coord 0014) saved,
# reached with r.
apps: $(FW_BUILD)/boot_ext_sim.hex

$(FW_BUILD)/boot_ext_sim.hex: $(FW_BUILD)/boot.hex $(FW_BUILD)/apps/exttest.bin scripts/mkimage.py
	python3 scripts/mkimage.py $(FW_BUILD)/boot.bin $(FW_BUILD)/apps/exttest.bin $@

# The GEMM accelerator self-test (sw/apps/gemmtest.c) with its driver
# (sw/lib/gemm.c), which moves the matrices with the DMA driver, and the
# array clock driver (sw/lib/aclk.c).
$(FW_BUILD)/apps/gemmtest.elf: sw/apps/gemmtest.c sw/lib/gemm.c sw/lib/gemm.h sw/lib/dma.c sw/lib/dma.h sw/lib/aclk.c sw/lib/aclk.h $(DMA_INC)/dmaeng_regs.h $(APP_DEPS)
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc $(APP_CFLAGS) -I$(DMA_INC) -o $@ sw/app/crt0.S sw/lib/io.c sw/lib/dma.c sw/lib/gemm.c sw/lib/aclk.c $< -lgcc

apps: $(FW_BUILD)/boot_gemm_sim.hex

# The accelerator against software matmul (sw/apps/matbench.c, Phase H),
# twice: RV32I (shift-add multiply) and RV32IM (matbench_m: mul, for a board
# built with M=1). Same driver as gemmtest, no array clock.
MATBENCH_DEPS := sw/apps/matbench.c sw/lib/gemm.c sw/lib/gemm.h sw/lib/dma.c sw/lib/dma.h $(DMA_INC)/dmaeng_regs.h $(APP_DEPS)
MATBENCH_SRCS := sw/app/crt0.S sw/lib/io.c sw/lib/dma.c sw/lib/gemm.c sw/apps/matbench.c

$(FW_BUILD)/apps/matbench.elf: $(MATBENCH_DEPS)
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc $(APP_CFLAGS) -I$(DMA_INC) -o $@ $(MATBENCH_SRCS) -lgcc

$(FW_BUILD)/apps/matbench_m.elf: $(MATBENCH_DEPS)
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc $(subst -march=rv32i ,-march=rv32im ,$(APP_CFLAGS)) -I$(DMA_INC) -o $@ $(MATBENCH_SRCS) -lgcc

apps: $(FW_BUILD)/apps/matbench_m.bin

# The tiny-LLM demo (Phase H; sw/llm/, golden model sw/model/llm_model.py):
# llama2.c's stories260K, integer only. The weights are fetched once from
# Karpathy's tinyllamas (MIT) into sw/build/llm/ and checked by SHA-256 in
# the model; `llm_model.py export` turns them into the blob the firmware
# links, its header, and the vectors it must reproduce.
#   make llm-model  the integer model against float (and float against
#                   llama2.c's run.c, by its recorded tokens)
#   make llm-host   sw/llm/llm.c built natively, bit-exact with the model
#   make llm        the board program (sw/build/llm/llm.bin, for the LLM
#                   build: make impl M=1 LLM=1) and its simulation image
LLM_DIR  := $(FW_BUILD)/llm
LLM_URL  := https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K
LLM_GEN  := $(LLM_DIR)/llm_blob.bin $(LLM_DIR)/llm_blob.h $(LLM_DIR)/llm_vectors.txt
LLM_SRCS := sw/app/crt0.S sw/lib/io.c sw/lib/dma.c sw/lib/gemm.c sw/llm/llm.c \
            sw/llm/llm_app.c sw/llm/llm_blob.S
LLM_DEPS := $(LLM_SRCS) sw/llm/llm.h sw/llm/link.ld sw/lib/gemm.h sw/lib/dma.h \
            sw/lib/io.h sw/lib/soc.h $(DMA_INC)/dmaeng_regs.h $(LLM_GEN)
LLM_CFLAGS := $(subst -march=rv32i ,-march=rv32im ,$(filter-out -Tsw/app/link.ld,$(APP_CFLAGS))) \
              -Tsw/llm/link.ld -Isw/llm -I$(LLM_DIR) -Wa,-I$(LLM_DIR) -I$(DMA_INC)
# The LLM build's RAM: 384 KiB, RAM_WORDS 98304 (make impl LLM=1).
LLM_RAM_END := 0x60000u

$(LLM_DIR)/stories260K.bin $(LLM_DIR)/tok512.bin:
	@mkdir -p $(@D)
	curl -fsSL -o $@ $(LLM_URL)/$(@F)

$(LLM_GEN) &: sw/model/llm_model.py $(LLM_DIR)/stories260K.bin $(LLM_DIR)/tok512.bin
	$(GEMM_PY) sw/model/llm_model.py export $(LLM_DIR) $(LLM_DIR)

.PHONY: llm-model llm-host llm
llm-model: $(LLM_DIR)/stories260K.bin $(LLM_DIR)/tok512.bin
	$(GEMM_PY) sw/model/llm_model.py check $(LLM_DIR)

$(LLM_DIR)/llm_host: sw/llm/llm_host.c sw/llm/llm.c sw/llm/llm.h sw/llm/llm_blob.S $(LLM_GEN)
	$(CC) -O2 -Wall -Wextra -Werror -Isw/llm -I$(LLM_DIR) -Wa,-I$(LLM_DIR) -o $@ sw/llm/llm_host.c sw/llm/llm_blob.S

llm-host: $(LLM_DIR)/llm_host
	$(LLM_DIR)/llm_host > $(LLM_DIR)/llm_host.txt
	grep -v '^#' $(LLM_DIR)/llm_vectors.txt | diff - $(LLM_DIR)/llm_host.txt
	@echo "llm-host: bit-exact with the golden model"

llm: $(LLM_DIR)/llm.bin $(FW_BUILD)/boot_llm.hex $(FW_BUILD)/boot_llm_sim.hex

$(LLM_DIR)/llm.elf: $(LLM_DEPS)
	$(RISCV_PREFIX)gcc $(LLM_CFLAGS) -o $@ $(LLM_SRCS) -lgcc

# For simulation (tb/cocotb/test_llm.py): three positions per run.
$(LLM_DIR)/llm_sim.elf: $(LLM_DEPS)
	$(RISCV_PREFIX)gcc $(LLM_CFLAGS) -DLLM_RUN_POS=3 -o $@ $(LLM_SRCS) -lgcc

$(LLM_DIR)/%.bin: $(LLM_DIR)/%.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# The bootloader for the LLM build: the same source, told the RAM's size.
$(FW_BUILD)/boot_llm.elf: sw/boot/boot.c sw/boot/crt0.S sw/boot/link.ld sw/lib/soc.h
	@mkdir -p $(FW_BUILD)
	$(RISCV_PREFIX)gcc $(BOOT_CFLAGS) -DRAM_END=$(LLM_RAM_END) -o $@ sw/boot/crt0.S sw/boot/boot.c

$(FW_BUILD)/boot_llm_sim.hex: $(FW_BUILD)/boot_llm.hex $(LLM_DIR)/llm_sim.bin scripts/mkimage.py
	python3 scripts/mkimage.py $(FW_BUILD)/boot_llm.bin $(LLM_DIR)/llm_sim.bin $@

# For simulation (tb/cocotb/test_gemm.py): the bootloader with gemmtest saved.
$(FW_BUILD)/boot_gemm_sim.hex: $(FW_BUILD)/boot.hex $(FW_BUILD)/apps/gemmtest.bin scripts/mkimage.py
	python3 scripts/mkimage.py $(FW_BUILD)/boot.bin $(FW_BUILD)/apps/gemmtest.bin $@

# For simulation (tb/cocotb/test_demo.py): the bootloader with the demo reel
# already loaded and saved, so the test reaches it with one key, r.
$(FW_BUILD)/boot_demo_sim.hex: $(FW_BUILD)/boot.hex $(FW_BUILD)/apps/demo.bin scripts/mkimage.py
	python3 scripts/mkimage.py $(FW_BUILD)/boot.bin $(FW_BUILD)/apps/demo.bin $@

# Kept: the .elf is what objdump and an ILA trigger (make gui VIEW=ila) read.
.PRECIOUS: $(FW_BUILD)/apps/%.elf

$(FW_BUILD)/apps/%.bin: $(FW_BUILD)/apps/%.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

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

# The M extension: rv32um on the C model with M on, then both models against
# sw/model/m_vectors.txt, spike's results (regenerate with make m-vectors,
# which needs spike; the file is committed so this check does not).
RV32UM      := $(basename $(notdir $(wildcard sw/riscv-tests/isa/rv32um/*.S)))

.PHONY: model-test m-vectors
model-test: $(MODEL_BUILD)/rv32ui_check $(MODEL_BUILD)/m_check \
            $(RV32UI:%=$(MODEL_BUILD)/rv32ui/%.bin) $(RV32UM:%=$(MODEL_BUILD)/rv32um/%.bin)
	$(MODEL_BUILD)/rv32ui_check $(RV32UI:%=$(MODEL_BUILD)/rv32ui/%.bin)
	$(MODEL_BUILD)/rv32ui_check -m $(RV32UM:%=$(MODEL_BUILD)/rv32um/%.bin)
	$(MODEL_BUILD)/m_check $(MODEL_DIR)/m_vectors.txt
	python3 $(MODEL_DIR)/m_check.py $(MODEL_DIR)/m_vectors.txt

m-vectors:
	python3 scripts/m_vectors.py $(MODEL_DIR)/m_vectors.txt

$(MODEL_BUILD)/m_check: $(MODEL_DIR)/m_check.c $(MODEL_DIR)/rv32i_iss.c $(MODEL_DIR)/rv32i_iss.h
	@mkdir -p $(@D)
	cc -std=c11 -O2 -Wall -Wextra -Werror -o $@ $(MODEL_DIR)/m_check.c $(MODEL_DIR)/rv32i_iss.c

$(MODEL_BUILD)/rv32um/%.bin: sw/riscv-tests/isa/rv32um/%.S
	@mkdir -p $(@D)
	$(RISCV_PREFIX)gcc -march=rv32im -mabi=ilp32 -static -nostdlib -nostartfiles \
		-Isw/riscv-tests-env -Isw/riscv-tests/isa/macros/scalar \
		-Tsw/riscv-tests-env/link.ld -o $(@:.bin=.elf) $<
	$(RISCV_PREFIX)objcopy -O binary $(@:.bin=.elf) $@

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
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) riscv_core_tmr

# The core and the TMR core built with MEM_WAIT = 1 (the data-port wait,
# Phase G): what the hold costs. Reports *_ooc_wait.*, *_ooc_tmr_wait.*.
.PHONY: synth-wait
synth-wait:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) riscv_core wait
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) riscv_core_tmr wait

# The core and the TMR core built with M_EXT = 1 (RV32IM, Phase H): what M
# costs. Reports *_ooc_m.* and *_ooc_tmr_m.*.
.PHONY: synth-m
synth-m:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) riscv_core m
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) riscv_core_tmr m

# The systolic array alone, out of context (Phase F): ARRAY=<rows>x<cols>.
# Reports docs/reports/*_ooc_array<rows>x<cols>.*, with the DSP count.
ARRAY ?= 16x16
.PHONY: synth-array
synth-array:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) systolic_array $(subst x, ,$(ARRAY))

# The DMA engine alone, out of context (Phase G): DMA_TOP (dmaeng_regs, the
# AXI4-Lite register slave, until the engine exists). Reports
# docs/reports/*_ooc_<DMA_TOP>.*.
DMA_TOP ?= dmaeng_regs
.PHONY: synth-dma
synth-dma:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) $(DMA_TOP)

# The GEMM accelerator alone, out of context (Phase G): the 16x16 array,
# its buffers, sequencer and bus ports. Reports docs/reports/*_ooc_gemm_accel.*.
# ACCEL_CDC=1: built with ARRAY_CDC = 1, the array on its own clock (Phase H),
# two clocks and a report_cdc; reports *_ooc_gemm_accel_cdc.*.
.PHONY: synth-accel
synth-accel:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) gemm_accel $(if $(filter 1,$(ACCEL_CDC)),cdc)

# The M-extension unit alone, out of context (Phase H): what MUL/DIV cost
# before they are in the core. Reports docs/reports/*_ooc_riscv_muldiv.*.
.PHONY: synth-muldiv
synth-muldiv:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) riscv_muldiv

# An asynchronous FIFO alone, out of context (array clock domain, Phase H):
# CDC_FIFO=<width>x<depth>, default the input stream's 259 bits by 16. Two
# 100 MHz clocks, crossings bounded (constr/cdc_ooc.xdc). Reports
# docs/reports/*_ooc_cdc_fifo<width>x<depth>.*, with report_cdc and
# report_bus_skew.
CDC_FIFO ?= 259x16
.PHONY: synth-cdc
synth-cdc:
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/synth_ooc.tcl -tclargs $(PART) cdc_async_fifo $(subst x, ,$(CDC_FIFO))

# --- array clock control against AMD's own code (Phase H box 4) -----------
# Local only: reads the Vivado install (VIVADO_DATA), as synth does. First
# the golden model's DRP words (sw/model/mmcm_drp.py) against AMD's
# mmcm_pll_count_calc for every divide 1-128; then array_clk_ctl.sv driving
# AMD's MMCME2_ADV simulation model (Icarus, tb/cocotb/test_aclk.py):
# 100 -> 80 -> 100 -> 80 MHz measured on its output.
VIVADO_DATA ?= $(HOME)/Xilinx/2025.2/data
ACLK_BUILD  := tb/aclk/build

.PHONY: aclk-check
aclk-check:
	@test -f $(VIVADO_DATA)/ip/xilinx/clk_wiz_v6_0/mmcm_pll_drp_func_7s_mmcm.vh || \
		{ echo "aclk-check: no Vivado data at $(VIVADO_DATA)"; exit 1; }
	$(GEMM_PY) sw/model/mmcm_drp.py
	@mkdir -p $(ACLK_BUILD)
	iverilog -g2005 -I $(VIVADO_DATA)/ip/xilinx/clk_wiz_v6_0 -o $(ACLK_BUILD)/table.vvp tb/aclk/amd_divider_table.v
	vvp -n $(ACLK_BUILD)/table.vvp | grep -v finish > $(ACLK_BUILD)/amd.txt
	$(GEMM_PY) sw/model/mmcm_drp.py --table > $(ACLK_BUILD)/model.txt
	diff $(ACLK_BUILD)/amd.txt $(ACLK_BUILD)/model.txt
	@echo "aclk-check: model's DRP words = AMD's, divides 1-$$(wc -l < $(ACLK_BUILD)/model.txt)"
	$(MAKE) -C tb/cocotb TEST_ONE=aclk_tb:test_aclk UNISIM=$(VIVADO_DATA)/verilog/src

# ram_dp built with SKY130_SRAM (the ASIC flow's memories, OpenRAM macros)
# against a reference memory, random traffic on both ports, at one 1 KiB
# macro, two and sixteen 2 KiB macros (tb/asic/ram_dp_sram_tb.v). Local:
# reads the PDK's behavioural models (PDK_ROOT, as LibreLane resolves it).
PDK_ROOT   ?= $(HOME)/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71
SRAM_V     := $(PDK_ROOT)/sky130A/libs.ref/sky130_sram_macros/verilog
SRAM_BUILD := tb/asic/build

.PHONY: sram-check
sram-check:
	@test -d $(SRAM_V) || { echo "sram-check: no OpenRAM models at $(SRAM_V)"; exit 1; }
	@mkdir -p $(SRAM_BUILD)
	@for w in 256 1024 8192; do \
	  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -DSKY130_SRAM -GWORDS=$$w \
	    --top-module ram_dp_sram_tb -Mdir $(SRAM_BUILD)/w$$w -o sim tb/asic/ram_dp_sram_tb.v rtl/top/ram_dp.sv \
	    $(SRAM_V)/sky130_sram_2kbyte_1rw1r_32x512_8.v $(SRAM_V)/sky130_sram_1kbyte_1rw1r_32x256_8.v \
	    > $(SRAM_BUILD)/w$$w.log 2>&1 || { echo "sram-check: build failed, $(SRAM_BUILD)/w$$w.log"; exit 1; }; \
	  $(SRAM_BUILD)/w$$w/sim | grep -a "^sram-check" | tee $(SRAM_BUILD)/w$$w.txt; \
	  grep -q " ok, " $(SRAM_BUILD)/w$$w.txt || exit 1; \
	done

# --- TMR fault injection ---------------------------------------------------
# The documented campaign (CLAUDE.md 5.7): FAULTS random single-bit flips into
# the TMR core, each in a fresh random program, judged against the golden
# model (tb/cocotb/test_tmr_faults.py). The regression runs 1000; this runs
# the full count and commits the summary.
FAULTS ?= 10000

.PHONY: faults
# M=1: the RV32IM TMR core, RV32IM programs, the M unit's flops among the
# targets; report docs/reports/tmr_faults_m.txt.
FAULTS_SFX := $(if $(filter 1,$(M)),_m,)
faults:
	FAULTS=$(FAULTS) SEED=$(SEED) $(MAKE) -C tb/cocotb TEST_ONE=riscv_core_tmr$(FAULTS_SFX):test_tmr_faults
	cp tb/cocotb/sim_build/tmr_faults$(FAULTS_SFX).txt docs/reports/tmr_faults$(FAULTS_SFX).txt

# --- UVM -------------------------------------------------------------------
# The Phase C regression in XSim (tb/uvm/, docs/coverage-plan.md): random
# programs checked retirement by retirement against the C golden model, and
# fails below COV_MIN percent functional coverage.
#   make uvm SEED=7 PROGRAMS=300 COV_MIN=95
# M=1: the core built with M_EXT (RV32IM, Phase H); coverage adds group 9.
SEED     ?= 1
PROGRAMS ?= 300
COV_MIN  ?= 95
M        ?= 0

.PHONY: uvm
uvm:
	scripts/setup-vivado-env.sh bash tb/uvm/run.sh $(SEED) $(PROGRAMS) $(COV_MIN) $(M)

# --- board -----------------------------------------------------------------
# Board-level synthesis, place & route and bitstream for the Arty A7 (Phase D):
# rtl/top/arty_a7_top.sv with the first-light firmware in its RAM. See
# syn/impl_arty.tcl; reports land in docs/reports/*_board.*, the bitstream in
# syn/build/board/.
BIT := syn/build/board/arty_a7_top.bit

.PHONY: impl prog ila
# FW_IMAGE picks the program the bitstream's RAM holds: the bootloader by
# default, or e.g. FW_IMAGE=sw/build/coremark.hex for the benchmark.
# ILA=1 attaches a logic analyser to the core's pipeline registers and writes
# its probes file beside the bitstream; its reports stay in syn/build/board/,
# so docs/reports/ always describes the design without debug logic. TMR=1
# builds the three-copy core, reports to docs/reports/*_board_tmr.*. M=1
# builds RV32IM core(s), reports *_board[_tmr]_m.*: with FW_IMAGE=
# sw/build/coremark_m.hex for RV32IM CoreMark. CDC=1 puts the systolic array
# on its own clock from a second MMCM (ARRAY_CDC, Phase H), reports
# *_board[_tmr][_m]_cdc.*. LLM=1 gives the RAM 384 KiB for the tiny-LLM
# demo (sw/llm/; with M=1), its own bootloader, reports *_llm.*. EXT=1 adds
# the SoC's external window (EXT_EN, fpga-coord 0014) with a 16-word register
# file on it, reports *_ext.*.
LLM      ?= 0
EXT      ?= 0
FW_IMAGE ?= $(FW_BUILD)/$(if $(filter 1,$(LLM)),boot_llm,boot).hex
ILA      ?= 0
TMR      ?= 0
CDC      ?= 0

impl: $(FW_IMAGE)
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/impl_arty.tcl -tclargs $(PART) $(FW_IMAGE) $(ILA) $(TMR) $(M) $(CDC) $(LLM) $(EXT)

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

# Program an ILA build (make impl ILA=1) from WSL and capture one window of
# the core's pipeline registers to syn/build/board/ila_capture.{csv,vcd},
# then check it (scripts/ila_check.py): each pipeline stage after ID must
# hold, one cycle later, what the stage before it held. Needs the Arty
# attached with usbipd; Hardware Manager's GUI reads the same .bit and .ltx.
LTX := $(BIT:.bit=.ltx)

ila:
	@test -f $(LTX) || { echo "no $(LTX): run make impl ILA=1 first" >&2; exit 1; }
	$(VIVADO) -mode batch -nojournal -notrace \
		-source syn/ila_capture.tcl -tclargs $(abspath $(BIT)) $(abspath $(LTX)) $(abspath syn/build/board)
	python3 scripts/ila_check.py syn/build/board/ila_capture.csv syn/build/board/ila_summary.txt

# Open the last make impl's routed design in the Vivado GUI (syn/gui_view.tcl):
# device view colored by module, worst path, schematic, timing, utilization,
# power. VIEW=rtl opens the elaborated RTL schematic instead; VIEW=array the
# 16x16 systolic array (make synth-array) coloured by row, VIEW=pair one PE
# pair as elaborated RTL. VIEW=ila
# programs an ILA build (make impl ILA=1) and shows a capture as waveforms,
# triggered when the function ILA_TRIGGER of ILA_ELF enters EX (one the code
# calls: GCC inlines some, e.g. core_list_find, leaving a dead copy); the Arty must
# be attached to WSL. Looking only.
VIEW        ?= routed
ILA_ELF     ?= $(FW_BUILD)/coremark.elf
ILA_TRIGGER ?= core_state_transition

.PHONY: gui
gui:
	$(VIVADO) -mode gui -nojournal -nolog -source syn/gui_view.tcl -tclargs $(VIEW) $(PART) \
		$(if $(filter rtl,$(VIEW)),$(TMR)) \
		$(if $(filter ila,$(VIEW)),$(abspath $(BIT)) $(abspath $(LTX)) \
		$$($(RISCV_PREFIX)nm $(ILA_ELF) | awk '$$3 == "$(ILA_TRIGGER)" {print $$1}'))

# Draw the last make impl's placement and routing as zoomable SVGs
# (syn/floorplan_export.tcl, scripts/floorplan.py): the whole die, and the
# same drawing cropped to the SoC. Refuses an ILA build, so the committed
# drawing is of the design the committed reports describe.
FLOORPLAN_DIR := syn/build/board/floorplan

.PHONY: floorplan
floorplan:
	@test -f syn/build/board/post_route.dcp || { echo "no routed design: run make impl first" >&2; exit 1; }
	@test ! -f $(LTX) || { echo "the routed design is an ILA build: run make impl without ILA=1 first" >&2; exit 1; }
	$(VIVADO) -mode batch -nojournal -notrace -source syn/floorplan_export.tcl \
		-tclargs syn/build/board/post_route.dcp $(FLOORPLAN_DIR)
	python3 scripts/floorplan.py $(FLOORPLAN_DIR) docs/img/floorplan_board.svg docs/img/floorplan_board_core.svg

# --- not yet built ---------------------------------------------------------
# Each names its phase and what it is waiting on. Fail loudly, not silently.
.PHONY: asic

# LibreLane RTL-to-GDSII on Sky130 (CLAUDE.md §6.4): run #1 is the bare
# non-TMR core (syn/asic_config.yaml), run #2 the full SoC in Phase H
# (SOC=1: syn/asic_soc.yaml, asic_top with 48 SRAM macros).
# Runs inside LibreLane's nix-shell (a clone at LIBRELANE_DIR, tag 3.0.16);
# the run lands in syn/build/asic/runs/asic<suffix>/.
LIBRELANE_DIR ?= $(HOME)/librelane
# SCAN=1 adds scan chains (syn/asic_scan.yaml, steps in
# syn/librelane_plugin_scan), then traces them and shifts every chain at
# gate level on the routed netlist (scripts/scan_chains.py,
# scan_shift_tb.py). Reports carry the suffix: _soc, _scan, _soc_scan.
SOC  ?= 0
SCAN ?= 0
ASIC_SFX  := $(if $(filter 1,$(SOC)),_soc,)$(if $(filter 1,$(SCAN)),_scan,)
ASIC_TOP  := $(if $(filter 1,$(SOC)),asic_top,riscv_core)
ASIC_TAG  := asic$(ASIC_SFX)
ASIC_CFGS := $(abspath syn/asic_$(if $(filter 1,$(SOC)),soc,config).yaml) $(if $(filter 1,$(SCAN)),$(abspath syn/asic_scan.yaml),)
ASIC_RUN  := syn/build/asic/runs/$(ASIC_TAG)
# SoC: no LEF view of asic_top (only for reuse as a macro; out of memory). syn/asic_soc.yaml
ASIC_SKIP := $(if $(filter 1,$(SOC)),--skip Magic.WriteLEF --skip Odb.CheckDesignAntennaProperties,)
ASIC_CHK  := $(ASIC_RUN)/check
CELL_V     = $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog
# SCAN=1 coverage tools: Fault 0.9.4 (fault cut, nl2bench) and the Quaigh it
# pins, patched to fit the SoC in memory (scripts/quaigh.nix). Fault's own test
# of the PRNG path fails, so checks are off (docs/design-notes.md, "Fault,
# tried 2026-11-09"); that path is not used.
FAULT_NIX := (builtins.getFlake "github:AUCOHL/Fault/0.9.4").packages.x86_64-linux.default.overrideAttrs (_: { doCheck = false; doInstallCheck = false; })
# SoC: the SRAM liberties with addr0/addr1/wmask0's 40 ps max_transition
# raised to the 0.5 ns the same file gives every other input (syn/asic_soc.yaml).
SRAM_LIB_SRC := $(PDK_ROOT)/sky130A/libs.ref/sky130_sram_macros/lib
SRAM_LIB_DIR := syn/build/asic/sram_lib
SRAM_LIBS    := $(addprefix $(SRAM_LIB_DIR)/,sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib)

$(SRAM_LIB_DIR)/%.lib: $(SRAM_LIB_SRC)/%.lib
	@mkdir -p $(@D)
	sed 's/^\( *max_transition *: *\)0\.04;/\10.5;/' $< > $@
	@test "$$(grep -c 'max_transition *: *0\.5;' $@)" = 3 || { echo "$@: expected 3 raised max_transition lines"; rm -f $@; exit 1; }
	@! grep -q 'max_transition *: *0\.04' $@

# ASIC_FROM=<step id> resumes the existing run from that step (e.g.
# OpenROAD.DetailedRouting) on the run's saved state, instead of starting over.
ASIC_FROM ?=

asic: $(if $(filter 1,$(SOC)),$(SRAM_LIBS),)
	@mkdir -p syn/build/asic
	PYTHONPATH=$(abspath syn) nix-shell $(LIBRELANE_DIR)/shell.nix --run "librelane --run-tag $(ASIC_TAG) $(if $(ASIC_FROM),--from $(ASIC_FROM),--overwrite) $(ASIC_SKIP) \
		--design-dir $(abspath syn/build/asic) \
		-c VERILOG_FILES='$(abspath $(RTL))' $(ASIC_CFGS)"
	@mkdir -p $(ASIC_CHK)
	python3 scripts/asic_summary.py $(ASIC_RUN) $(ASIC_CHK)
	cp $(ASIC_CHK)/summary_asic.txt docs/reports/summary_asic$(ASIC_SFX).txt
ifneq ($(SCAN),1)
	cp $(ASIC_CHK)/sta_asic.rpt docs/reports/sta_asic$(ASIC_SFX).rpt
	cp $(ASIC_CHK)/manufacturability_asic.rpt docs/reports/manufacturability_asic$(ASIC_SFX).rpt
else
	python3 scripts/scan_chains.py $(ASIC_RUN)/final/nl/$(ASIC_TOP).nl.v --json $(ASIC_CHK)/chains.json \
		> $(ASIC_CHK)/chains.txt || { cat $(ASIC_CHK)/chains.txt; exit 1; }
	python3 scripts/scan_shift_tb.py $(ASIC_CHK)/chains.json $(ASIC_TOP) clk_i $(if $(filter 1,$(SOC)),--tie rst_i=0,) > $(ASIC_CHK)/shift_tb.v
	iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 -o $(ASIC_CHK)/shift.vvp $(ASIC_CHK)/shift_tb.v \
		$(ASIC_RUN)/final/nl/$(ASIC_TOP).nl.v $(CELL_V)/primitives.v $(CELL_V)/sky130_fd_sc_hd.v \
		$(if $(filter 1,$(SOC)),tb/asic/sram_blackbox.v,)
	vvp -n $(ASIC_CHK)/shift.vvp | grep -a "^scan-shift" > $(ASIC_CHK)/shift.txt
	{ echo "# Scan chains in the routed netlist (make asic SCAN=1), traced by scripts/scan_chains.py,"; \
	  echo "# shifted at gate level by scripts/scan_shift_tb.py (Icarus, sky130_fd_sc_hd models)"; echo; \
	  cat $(ASIC_CHK)/chains.txt; echo; cat $(ASIC_CHK)/shift.txt; } > docs/reports/scan_chains_asic$(subst _scan,,$(ASIC_SFX)).txt
	@cat docs/reports/scan_chains_asic$(subst _scan,,$(ASIC_SFX)).txt
	@grep -q " ok, " $(ASIC_CHK)/shift.txt
	fault=$$(nix build --impure --no-link --print-out-paths --expr '$(FAULT_NIX)') && \
	FAULT=$$fault/bin/fault NL2BENCH=$$fault/bin/nl2bench \
	QUAIGH=$$(nix build --impure --no-link --print-out-paths -f scripts/quaigh.nix)/bin/quaigh \
	python3 scripts/scan_coverage.py $(ASIC_RUN)/final/nl/$(ASIC_TOP).nl.v $(ASIC_TOP) \
		$(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib $(ASIC_CHK)/coverage
	cp $(ASIC_CHK)/coverage/coverage.txt docs/reports/scan_coverage_asic$(subst _scan,,$(ASIC_SFX)).txt
endif

# --- housekeeping ----------------------------------------------------------
.PHONY: clean
clean:
	$(MAKE) -C tb/cocotb clean
	rm -rf obj_dir tb/cocotb/dump.vcd tb/formal/build
	rm -f sw/prog.elf sw/prog.hex
	rm -rf syn/build .Xil
	rm -f vivado*.log vivado*.jou
