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

# TOP is exported by the root Makefile; default it so `make -C tb/cocotb`
# standalone does not silently elaborate with an empty TOPLEVEL.
TOP ?= riscv_core

# CURDIR, not PWD: make sets CURDIR to this makefile's own directory, whereas
# PWD is inherited from the invoking shell and does not follow `make -C`.
REPO := $(CURDIR)/../..

SIM             ?= verilator
TOPLEVEL_LANG   := verilog
TOPLEVEL        := $(TOP)
MODULE          ?= test_core
# Recursive, for the same reason as the root Makefile: rtl/ is nested, and a
# one-level glob would drop whole subdirectories without saying so.
VERILOG_SOURCES := $(shell find $(REPO)/rtl -name '*.sv' | sort)
EXTRA_ARGS      += --trace --trace-structs

ifeq ($(VERILOG_SOURCES),)
  $(error no .sv files found under $(REPO)/rtl)
endif

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
