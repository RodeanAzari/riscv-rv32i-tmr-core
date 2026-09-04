# RISC-V RV32I core — single entry point.
#   make lint   verilator lint of rtl/
#   make sim    cocotb regression on verilator (see tb/Makefile)
#   make sw     build sw/*.c to .elf and .hex
#   make spike  run the .elf on the spike reference model
#   make clean

XLEN_GCC := $(HOME)/riscv-toolchain/bin/riscv32-unknown-elf-gcc
ELF2HEX  := $(HOME)/riscv-toolchain/bin/elf2hex
SPIKE    := $(HOME)/riscv-toolchain/bin/spike

export TOP ?= riscv_core
RTL := $(wildcard rtl/*.sv)

# --- lint ------------------------------------------------------------------
.PHONY: lint
lint:
	verilator --lint-only -Wall --timing --top-module $(TOP) $(RTL)

# --- simulation ------------------------------------------------------------
.PHONY: sim
sim:
	$(MAKE) -C tb

# --- software --------------------------------------------------------------
CFLAGS_RV := -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -O2 -Tsw/link.ld
SW_SRCS   := $(wildcard sw/*.c)

.PHONY: sw
sw: sw/prog.hex

sw/prog.elf: $(SW_SRCS) sw/link.ld
	$(XLEN_GCC) $(CFLAGS_RV) -o $@ $(SW_SRCS)

sw/prog.hex: sw/prog.elf
	$(ELF2HEX) --bit-width 32 --input $< --output $@

.PHONY: spike
spike: sw/prog.elf
	$(SPIKE) --isa=rv32i $<

# --- housekeeping ----------------------------------------------------------
.PHONY: clean
clean:
	$(MAKE) -C tb clean
	rm -rf obj_dir
	rm -f sw/prog.elf sw/prog.hex
