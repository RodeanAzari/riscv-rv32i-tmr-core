#!/usr/bin/env bash
# Build and run the UVM regression in XSim. Called by `make uvm`, inside
# scripts/setup-vivado-env.sh so Vivado's tools are on PATH.
#
#   tb/uvm/run.sh <seed> <programs> <cov_min>
set -eo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
seed=${1:-1}; programs=${2:-300}; cov_min=${3:-95}
build="$repo/tb/uvm/build"
mkdir -p "$build"
cd "$build"

# The golden model and its DPI face, into the default DPI library.
xsc "$repo/tb/uvm/rv_dpi.c" "$repo/sw/model/rv32i_iss.c"

# The core only (rtl/core/): the board files name Xilinx primitives this
# elaboration does not need. RISCV_FORMAL for the RVFI port.
xvlog -sv -L uvm -d RISCV_FORMAL $(find "$repo/rtl/core" -name '*.sv' | sort) \
      "$repo/tb/uvm/core_if.sv" "$repo/tb/uvm/rv_pkg.sv" "$repo/tb/uvm/tb_top.sv"
xelab -L uvm -sv_lib dpi -timescale 1ns/1ps tb_top -s tb_top

xsim tb_top -R -sv_seed "$seed" \
     -testplusarg UVM_TESTNAME=rv_regress_test \
     -testplusarg PROGRAMS="$programs" -testplusarg COV_MIN="$cov_min" | tee sim.log

# UVM reports errors in the log, not in the exit status.
grep -q 'UVM_ERROR :    0' sim.log && grep -q 'UVM_FATAL :    0' sim.log
