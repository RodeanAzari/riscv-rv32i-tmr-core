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
  $(error cocotb-config not found: activate $(VENV) or pip install -r tb/requirements.txt)
endif

SIM             ?= verilator
TOPLEVEL_LANG   := verilog
TOPLEVEL        := $(TOP)
MODULE          ?= test_core
VERILOG_SOURCES := $(wildcard $(PWD)/../rtl/*.sv)
EXTRA_ARGS      += --trace --trace-structs

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
