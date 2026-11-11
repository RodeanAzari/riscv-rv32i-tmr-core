#!/usr/bin/env python3
"""Write a gate-level scan shift testbench (buildplan §6.5: "scan shift
verification in simulation").

Input: the chains JSON from scripts/scan_chains.py (traced on the same
netlist). The testbench holds scan enable high and, for 3 x the longest
chain cycles, drives an independent random bit into every scan_in each
cycle; each scan out must show, L cycles later, the bit that went in (L =
that chain's length; inverted if the chain's path inverts, which
scan_chains.py reports). Bits before the chain is first filled are not
checked. Only the clock and scan ports are connected: functional inputs
float (X), which the scan mux does not select during shift, so an X at a
scan out means the chain is broken.

Usage: scripts/scan_shift_tb.py <chains.json> <top module> <clock port> > tb.v
Run with Icarus and the PDK's cell models (make asic-scan-check).
"""

import json
import sys


def main():
    chains_json, top, clk = sys.argv[1:4]
    d = json.load(open(chains_json))
    chains = d["chains"]
    se = d["scan_enable"]
    longest = max(len(c["flops"]) for c in chains)
    cycles = 3 * longest + 4
    nch = len(chains)

    # output ports: whole ports or bits of a bus
    outs = {}
    for k, c in enumerate(chains):
        so = c["scan_out"]
        port, _, bit = so.partition("[")
        outs.setdefault(port, []).append((k, bit.rstrip("]") if bit else None))

    w = []
    w.append("`timescale 1ns/1ps")
    w.append("module scan_shift_tb;")
    w.append(f"  localparam integer NCH = {nch};")
    w.append(f"  localparam integer CYCLES = {cycles};")
    w.append("  reg clk = 0;")
    w.append("  always #20 clk = ~clk;")
    w.append(f"  reg [NCH-1:0] si = 0;")
    w.append("  wire [NCH-1:0] so;")
    w.append(f"  integer len [0:NCH-1];")
    w.append(f"  integer inv [0:NCH-1];")
    for port, lst in outs.items():
        width = max((int(b) for _, b in lst if b is not None), default=-1) + 1
        if width:
            w.append(f"  wire [{width - 1}:0] o_{port};")
            for k, b in lst:
                w.append(f"  assign so[{k}] = o_{port}[{b}];")
        else:
            w.append(f"  wire o_{port};")
            for k, _ in lst:
                w.append(f"  assign so[{k}] = o_{port};")
    conns = [f".{clk}(clk)", f".{se}(1'b1)"]
    conns += [f".{c['scan_in']}(si[{k}])" for k, c in enumerate(chains)]
    conns += [f".{port}(o_{port})" for port in outs]
    w.append(f"  {top} dut ({', '.join(conns)});")
    w.append(f"  reg [NCH-1:0] hist [0:CYCLES];")
    w.append("  integer n, k, errors, checked, seed;")
    w.append("  initial begin")
    for k, c in enumerate(chains):
        w.append(f"    len[{k}] = {len(c['flops'])}; inv[{k}] = {1 if c.get('inverted') else 0};")
    w.append("    errors = 0; checked = 0; seed = 7;")
    w.append("    for (n = 0; n < CYCLES; n = n + 1) begin")
    w.append("      @(negedge clk);")
    # check before driving this cycle's bit: after n rising edges, scan out
    # holds the bit driven before edge n - len + 1, i.e. hist[n - len]
    w.append("      for (k = 0; k < NCH; k = k + 1)")
    w.append("        if (n >= len[k]) begin")
    w.append("          checked = checked + 1;")
    w.append("          if (so[k] !== (hist[n - len[k]][k] ^ inv[k][0])) begin")
    w.append("            errors = errors + 1;")
    w.append("            if (errors < 10) $display(\"chain %0d cycle %0d: scan out %b, expected %b\", k, n, so[k], hist[n - len[k]][k] ^ inv[k][0]);")
    w.append("          end")
    w.append("        end")
    w.append("      si = $random(seed);")
    w.append("      hist[n] = si;")
    w.append("    end")
    w.append("    if (errors == 0 && checked > 0)")
    w.append(f"      $display(\"scan-shift: {nch} chains ok, %0d scan-out bits checked over %0d cycles\", checked, CYCLES);")
    w.append("    else")
    w.append("      $display(\"scan-shift: FAILED, %0d of %0d bits wrong\", errors, checked);")
    w.append("    $finish;")
    w.append("  end")
    w.append("endmodule")
    print("\n".join(w))


if __name__ == "__main__":
    main()
