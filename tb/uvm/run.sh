#!/usr/bin/env bash
# Build and run the UVM regression in XSim. Called by `make uvm`, inside
# scripts/setup-vivado-env.sh so Vivado's tools are on PATH.
#
#   tb/uvm/run.sh <seed> <programs> <cov_min> [m]
#
# m = 1: the core built with M_EXT (RV32IM, Phase H), its own snapshot and log.
set -eo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
seed=${1:-1}; programs=${2:-300}; cov_min=${3:-95}; m=${4:-0}
snap=tb_top; generic=()
if [ "$m" = 1 ]; then snap=tb_top_m; generic=(-generic_top M_EXT=1); fi
build="$repo/tb/uvm/build"
mkdir -p "$build"
cd "$build"

# The golden model and its DPI face, into the default DPI library.
xsc "$repo/tb/uvm/rv_dpi.c" "$repo/sw/model/rv32i_iss.c"

# The core only (rtl/core/): the board files name Xilinx primitives this
# elaboration does not need. RISCV_FORMAL for the RVFI port.
xvlog -sv -L uvm -d RISCV_FORMAL $(find "$repo/rtl/core" -name '*.sv' | sort) \
      "$repo/tb/uvm/core_if.sv" "$repo/tb/uvm/rv_pkg.sv" "$repo/tb/uvm/tb_top.sv"
xelab -L uvm -sv_lib dpi -timescale 1ns/1ps "${generic[@]}" tb_top -s "$snap"

xsim "$snap" -R -sv_seed "$seed" \
     -testplusarg UVM_TESTNAME=rv_regress_test \
     -testplusarg PROGRAMS="$programs" -testplusarg COV_MIN="$cov_min" | tee "$snap.log"

# UVM reports errors in the log, not in the exit status.
grep -q 'UVM_ERROR :    0' "$snap.log" && grep -q 'UVM_FATAL :    0' "$snap.log"
