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
VERILOG_SOURCES := $(shell find $(REPO)/rtl -name '*.sv' | sort)

ifeq ($(VERILOG_SOURCES),)
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

# One entry per elaboration, <toplevel module>:<python test module>.
#
# Submodules get their own toplevel rather than being poked through the core's
# hierarchy: a unit test that reaches into dut.u_regfile.mem breaks the moment
# the hierarchy is refactored, and it cannot drive a port the core does not
# expose. Each entry elaborates separately, so each needs its own build
# directory and results file or they overwrite each other.
TESTS ?= riscv_core:test_core \
         riscv_alu:test_alu \
         riscv_regfile:test_regfile \
         riscv_decoder:test_decoder \
         riscv_mem_align:test_mem_align \
         riscv_hazard:test_hazard

ifdef TEST_ONE
  TOPLEVEL              := $(word 1,$(subst :, ,$(TEST_ONE)))
  MODULE                := $(word 2,$(subst :, ,$(TEST_ONE)))
  SIM_BUILD             := sim_build/$(TOPLEVEL)
  COCOTB_RESULTS_FILE   := results_$(TOPLEVEL).xml
  include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
else

# Run every entry even if an earlier one fails, then fail if any did -- a
# regression should report all the broken things in one pass, not just the
# first.
.PHONY: all
all:
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
