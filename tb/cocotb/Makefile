# cocotb regression, driven from the repo root by `make sim`.
#
# Uses the venv at $(VENV) when it exists, otherwise whatever cocotb is on
# PATH -- CI installs cocotb directly rather than into a venv.
VENV ?= $(HOME)/cocotb-env

ifneq ($(wildcard $(VENV)/bin/cocotb-config),)
  export PATH := $(VENV)/bin:$(PATH)
endif
COCOTB_CONFIG := $(shell command -v cocotb-config)
ifeq ($(COCOTB_CONFIG),)
  $(error cocotb-config not found: activate $(VENV) or pip install -r tb/cocotb/requirements.txt)
endif

# CURDIR, not PWD: make sets CURDIR to this makefile's own directory, whereas
# PWD is inherited from the invoking shell and does not follow `make -C`.
REPO := $(CURDIR)/../..

# Recursive, for the same reason as the root Makefile: rtl/ is nested, and a
# one-level glob would drop whole subdirectories without saying so.
# DMA-Engine's register package first, as in the root Makefile.
RTL_SOURCES     := $(shell find $(REPO)/rtl -name '*.sv' | sort)
VERILOG_SOURCES := $(REPO)/sw/dma-engine/rtl/dmaeng_pkg.sv $(RTL_SOURCES)

ifeq ($(RTL_SOURCES),)
  $(error no .sv files found under $(REPO)/rtl)
endif

SIM           ?= verilator
TOPLEVEL_LANG := verilog
# Waveforms on demand: `make sim WAVES=1`. Off by default because the VCD costs
# build and run time on every regression and is only ever read once something
# has already failed.
#
# Delegated to cocotb's own VERILATOR_TRACE rather than hand-rolled, because
# tracing needs TWO flags that are easy to confuse: --trace at compile time to
# generate the trace code, and --trace again at run time to open the file.
# Setting only the compile flag builds a trace-capable binary that silently
# writes nothing. (Putting them in EXTRA_ARGS appears to work, because cocotb
# passes EXTRA_ARGS to both the compile and the simulation binary -- but it
# also drops --trace-structs onto the runtime command line, where it is not a
# valid argument.)
ifdef WAVES
  VERILATOR_TRACE := 1
endif

# The RVFI port exists only under RISCV_FORMAL (rtl/core/riscv_core.sv), and
# the core tests check every retirement through it. COMPILE_ARGS, not
# EXTRA_ARGS: a define belongs on the Verilator command line only, for the
# same reason as --trace-structs above.
#
# FORMAL compiles in the property blocks the formal proofs use, and --assert
# makes Verilator evaluate them: every test then checks every property on
# every cycle it runs. A failing assertion stops the simulation with the
# file and line of the property, which the test reports as a failure.
COMPILE_ARGS += -DRISCV_FORMAL -DFORMAL --assert $(REPO)/tb/lint/waivers.vlt

# One entry per elaboration, <toplevel module>:<python test modules>.
#
# Submodules get their own toplevel rather than being poked through the core's
# hierarchy: a unit test that reaches into dut.u_regfile.mem breaks the moment
# the hierarchy is refactored, and it cannot drive a port the core does not
# expose. Each entry elaborates separately, so each needs its own build
# directory and results file or they overwrite each other. Several modules
# against one toplevel share an entry, comma-separated: test_riscv_tests runs
# the official suite on the same core build as test_core. riscv_core_tmr
# runs both again on the triplicated core, which has the core's ports.
TESTS ?= riscv_core:test_core,test_riscv_tests \
         riscv_core_tmr:test_core,test_riscv_tests \
         riscv_core_tmr:test_tmr_faults \
         riscv_core_wait:test_core,test_riscv_tests \
         riscv_core_tmr_wait:test_core,test_riscv_tests \
         riscv_alu:test_alu \
         riscv_muldiv:test_muldiv \
         riscv_regfile:test_regfile \
         riscv_decoder:test_decoder \
         riscv_mem_align:test_mem_align \
         riscv_hazard:test_hazard \
         riscv_branch:test_branch \
         uart_tx:test_uart_tx \
         uart_rx:test_uart_rx \
         systolic_pe:test_systolic_pe \
         systolic_pe_pair:test_systolic_pe_pair \
         systolic_array:test_systolic_array \
         systolic_array_16x16:test_systolic_array \
         systolic_array_4x8:test_systolic_array \
         dmaeng_regs:test_dmaeng_regs \
         dmaeng:test_dmaeng \
         axi_xbar:test_axi_xbar \
         gemm_accel_4x4:test_gemm_accel \
         gemm_accel_4x8:test_gemm_accel \
         gemm_accel:test_gemm_accel \
         soc:test_soc \
         soc:test_coremark \
         soc:test_boot \
         soc:test_demo \
         soc:test_dma \
         soc:test_gemm \
         soc_tmr:test_soc \
         soc_tmr:test_coremark \
         soc_tmr:test_boot \
         soc_tmr:test_demo \
         soc_tmr:test_dma \
         soc_tmr:test_gemm

# The SoC runs a firmware simulation image from sw/build/, built by `make fw`
# and `make bench` (the regression below builds both first; a TEST_ONE run of
# soc needs them built): first light for test_soc, CoreMark for
# test_coremark, the bootloader for test_boot (with sw/build/apps/ for the
# programs it sends; `make boot apps`). The image path is a compile-time parameter, so each gets its
# own build directory and results file. Read by $readmemh when the
# simulation starts, so a rebuilt image needs no recompile.
ifdef TEST_ONE
  TOPLEVEL              := $(word 1,$(subst :, ,$(TEST_ONE)))
  MODULE                := $(word 2,$(subst :, ,$(TEST_ONE)))
  BUILD_TAG             := $(TOPLEVEL)
  # soc_tmr: the same SoC built with TMR = 1 (three voted cores); the tests
  # then also require the mismatch counter to stay at zero.
  TMR_SUFFIX            :=
  ifeq ($(TOPLEVEL),soc_tmr)
    TOPLEVEL            := soc
    TMR_SUFFIX          := _tmr
    COMPILE_ARGS        += -GTMR=1
  endif
  ifeq ($(TOPLEVEL),soc)
    SOC_IMAGE           := $(if $(filter test_coremark,$(MODULE)),coremark_sim,$(if $(filter test_boot,$(MODULE)),boot,$(if $(filter test_demo,$(MODULE)),boot_demo_sim,$(if $(filter test_dma,$(MODULE)),boot_dma_sim,$(if $(filter test_gemm,$(MODULE)),boot_gemm_sim,hello_sim)))))
    BUILD_TAG           := soc_$(SOC_IMAGE)$(TMR_SUFFIX)
    # The demo, DMA and GEMM tests run the UART at CLK/16: their output is
    # thousands of characters.
    ifneq ($(filter test_demo test_dma test_gemm,$(MODULE)),)
      COMPILE_ARGS      += -GBAUD=3125000
    endif
    ifeq ($(MODULE),test_demo)
      # On TMR, the fault-injection demo only: the other six are the plain
      # SoC's tests, and would add twenty minutes for nothing TMR-specific.
      # It injects faults, so no in-RTL assertions (see test_tmr_faults below).
      ifeq ($(TMR_SUFFIX),_tmr)
        export COCOTB_TEST_FILTER := test_tmr
        COMPILE_ARGS    := $(filter-out -DFORMAL --assert,$(COMPILE_ARGS))
      endif
    endif
    COMPILE_ARGS        += -GINIT_FILE='"$(abspath $(REPO)/sw/build/$(SOC_IMAGE).hex)"'
  endif
  # systolic_array_<ROWS>x<COLS>: the array at another size than its default
  # 4x4. The test reads the shape from the port widths.
  ifneq ($(filter systolic_array_%,$(TOPLEVEL)),)
    ARRAY_SHAPE         := $(subst x, ,$(patsubst systolic_array_%,%,$(TOPLEVEL)))
    COMPILE_ARGS        += -GROWS=$(word 1,$(ARRAY_SHAPE)) -GCOLS=$(word 2,$(ARRAY_SHAPE))
    TOPLEVEL            := systolic_array
  endif
  # gemm_accel_<ROWS>x<COLS>: the accelerator at a small array, 2 KiB
  # buffers, so the tests reach every buffer limit quickly. Plain gemm_accel
  # is the SoC's 16x16 with 16 KiB.
  ifneq ($(filter gemm_accel_%,$(TOPLEVEL)),)
    ACCEL_SHAPE         := $(subst x, ,$(patsubst gemm_accel_%,%,$(TOPLEVEL)))
    COMPILE_ARGS        += -GROWS=$(word 1,$(ACCEL_SHAPE)) -GCOLS=$(word 2,$(ACCEL_SHAPE)) -GBUF_BYTES=2048
    TOPLEVEL            := gemm_accel
  endif
  # <core>_wait: the core built with MEM_WAIT = 1 (the data-port wait,
  # Phase G), its data port held low a random DMEM_WAIT of the cycles. Only
  # the tests that judge by retirements run: the golden-model random
  # programs, the official suite and the hold tests. The rest count cycles
  # or step the pipeline by hand, which a random hold would break.
  ifneq ($(filter %_wait,$(TOPLEVEL)),)
    TOPLEVEL            := $(patsubst %_wait,%,$(TOPLEVEL))
    COMPILE_ARGS        += -GMEM_WAIT=1
    export DMEM_WAIT    ?= 0.3
    # quoted: cocotb puts it on a shell command line as is
    export COCOTB_TEST_FILTER := 'test_hold|test_random|test_rv32ui'
  endif
  # The crossbar at the test's map: 3 masters, slave 0 at 0x0xxx_xxxx (the
  # RAM's region), slave 1 at 0x2000_0000-0x2000_0FFF; the rest DECERR.
  ifeq ($(TOPLEVEL),axi_xbar)
    COMPILE_ARGS        += -GN=3 -GM=2 -GS_BASE=64\'h2000000000000000 -GS_MASK=64\'hFFFFF000F0000000
  endif
  # The fault campaign breaks the pipeline's invariants on purpose, so the
  # core's in-RTL properties (FORMAL, --assert) would stop it at the first
  # flip: its build leaves them out, and has a build directory of its own.
  ifeq ($(MODULE),test_tmr_faults)
    COMPILE_ARGS        := $(filter-out -DFORMAL --assert,$(COMPILE_ARGS))
    BUILD_TAG           := $(TOPLEVEL)_faults
  endif
  SIM_BUILD             := sim_build/$(BUILD_TAG)
  COCOTB_RESULTS_FILE   := results_$(BUILD_TAG).xml
  include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
else

# Run every entry even if an earlier one fails, then fail if any did -- a
# regression should report all the broken things in one pass, not just the
# first.
.PHONY: all
all:
	$(MAKE) --no-print-directory -C $(REPO) fw bench boot apps
	@rc=0; \
	for t in $(TESTS); do \
	  echo "=== $$t ==="; \
	  $(MAKE) --no-print-directory TEST_ONE=$$t || rc=1; \
	done; \
	if [ $$rc -ne 0 ]; then echo "REGRESSION FAILED"; fi; \
	exit $$rc

.PHONY: clean
clean::
	rm -rf sim_build results_*.xml __pycache__ dump.vcd

endif
