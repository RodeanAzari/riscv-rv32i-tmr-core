#!/usr/bin/env bash
# riscv-formal on riscv_core: generate the checks, run them, and fail unless
# every one passed. Called by `make formal`.
#
# Usage: scripts/riscv-formal.sh <repo root> <jobs>
#
# Three things here that are easy to get wrong:
#
# 1. genchecks.py takes its bearings from the current directory: it treats
#    ../.. as riscv-formal's root and the directory's own name as the core's.
#    Rather than writing into the submodule, a small tree of symlinks under
#    tb/formal/build/rvf/ gives it the layout it expects:
#        rvf/checks, rvf/insns -> the submodule's
#        rvf/cores/riscv_core/{checks.cfg, wrapper.sv} -> tb/formal/rvfi/
#        rvf/cores/riscv_core/rtl -> rtl/core
#    and the same again as rvf/cores/riscv_core_m/ for checks_m.cfg: the
#    core built with M_EXT, M results as riscv-formal's ALTOPS (Phase H).
#
# 2. Two passes from ONE config. "checks" runs tb/formal/rvfi/checks.cfg as
#    written (bounded model checks). "covers" is the same config with
#    `mode cover` added, so every cover() in riscv-formal's checkers -- four
#    per instruction check, proving that instruction can retire, untrapped,
#    at the check cycle -- must be reached. A check whose scenario cannot
#    occur would otherwise pass vacuously (CLAUDE.md 5.5).
#
# 3. The generated .sby files say `expect pass,fail`, so sby exits 0 even
#    when a check FAILS, and so does the generated makefile. The verdict is
#    read from each check's status file instead, and the number of verdicts
#    must equal the number of checks generated, so a check that never ran
#    cannot pass by absence.
set -euo pipefail

repo=$(cd "$1" && pwd)
jobs=$2
rvf=$repo/tb/formal/riscv-formal
build=$repo/tb/formal/build/rvf

if [ ! -f "$rvf/checks/genchecks.py" ]; then
  echo "riscv-formal: $rvf is empty -- run: git submodule update --init" >&2
  exit 1
fi

rm -rf "$build"
mkdir -p "$build"
ln -s "$rvf/checks"                    "$build/checks"
ln -s "$rvf/insns"                     "$build/insns"

rc=0
for cfg in checks checks_m; do
core=$build/cores/riscv_core${cfg#checks}
mkdir -p "$core"
ln -s "$repo/tb/formal/rvfi/$cfg.cfg"  "$core/checks.cfg"
ln -s "$repo/tb/formal/rvfi/wrapper.sv" "$core/wrapper.sv"
ln -s "$repo/rtl/core"                 "$core/rtl"
sed 's/^isa \(rv32i.*\)$/isa \1\nmode cover/' "$core/checks.cfg" > "$core/covers.cfg"
grep -q '^mode cover$' "$core/covers.cfg" || { echo "covers.cfg: no mode line added" >&2; exit 1; }

for pass in checks covers; do
  echo "=== riscv-formal ($cfg.cfg): $pass ==="
  (cd "$core" && python3 ../../checks/genchecks.py "$pass" > /dev/null)
  expected=$(ls "$core/$pass"/*.sby | wc -l)
  (cd "$core/$pass" && make -j"$jobs" -k > make.log 2>&1) || true

  passed=0; failed=""
  for sby in "$core/$pass"/*.sby; do
    name=$(basename "$sby" .sby)
    status=$(cat "$core/$pass/$name/status" 2>/dev/null || echo "MISSING")
    case "$status" in
      PASS*) passed=$((passed + 1)) ;;
      *)     failed="$failed $name(${status%% *})" ;;
    esac
  done
  echo "$pass: $passed / $expected passed"
  if [ "$passed" -ne "$expected" ] || [ "$expected" -eq 0 ]; then
    echo "$pass FAILED:$failed" >&2
    echo "  logs: $core/$pass/<check>/logfile.txt, traces in <check>/engine_0/" >&2
    rc=1
  fi
done
done
exit $rc
