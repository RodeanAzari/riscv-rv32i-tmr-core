# cocotb regression, driven from the repo root by `make sim`.
VENV := $(HOME)/cocotb-env

SIM             ?= verilator
TOPLEVEL_LANG   := verilog
TOPLEVEL        := $(TOP)
MODULE          ?= test_core
VERILOG_SOURCES := $(wildcard $(PWD)/../rtl/*.sv)
EXTRA_ARGS      += --trace --trace-structs

export PATH := $(VENV)/bin:$(PATH)

include $(shell $(VENV)/bin/cocotb-config --makefiles)/Makefile.sim
