#!/usr/bin/env python3
"""Trace the scan chains in a LibreLane netlist (buildplan §6.5).

From each scan_in_<k> port, follow scan flop to scan flop: a flop whose SCD
(scan data) is on the net, then its Q net, until no flop's SCD is; that
last net must reach a top-level output. Buffers and inverters between (the
resizer's, the output buffers) are followed, inverters counted: a chain
with an odd count shifts inverted ("inverted" in the JSON). The path from
a net to the next SCD must be unique; of several outputs carrying the
chain's last bit (an output buffered onto another), the nearest is used (scan_out_<k>, or a functional
output OpenROAD reused as the chain's scan out). Checks: every scan flop on
exactly one chain, every flop a scan flop, every SCE driven, through
buffers only and not inverted, from one scan-enable input port. Prints one line per chain (length, scan in, scan out) and the totals;
exits nonzero on any failure.

Usage: scripts/scan_chains.py <netlist.nl.v> [--json out.json]
The JSON (chains in shift order, flop names) drives the shift simulation.
"""

import json
import re
import sys
from collections import defaultdict


def parse(path):
    text = open(path).read()
    text = re.sub(r"//[^\n]*", "", text)
    ports = {}
    for kind, rng, names in re.findall(r"\b(input|output)\s+(\[[^\]]+\])?\s*([^;]+);", text):
        for n in names.split(","):
            n = n.strip()
            if n:
                ports[n] = kind
    # assign <lhs> = <rhs>; (a port driven straight from a net)
    assigns = dict((l.strip(), r.strip()) for l, r in re.findall(r"assign\s+([^=]+)=\s*([^;]+);", text))
    cells = []
    for m in re.finditer(r"\b(sky130_\w+)\s+(\\?\S+)\s*\((.*?)\);", text, re.S):
        master, name, body = m.group(1), m.group(2), m.group(3)
        pins = dict((p, n.strip()) for p, n in re.findall(r"\.(\w+)\s*\(([^()]*)\)", body))
        cells.append((master, name, pins))
    return ports, assigns, cells


def main():
    path = sys.argv[1]
    out_json = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    ports, assigns, cells = parse(path)
    flops = [(m, n, p) for m, n, p in cells if re.search(r"__(s?df|edf)", m)]
    plain = [n for m, n, p in flops if "__sdf" not in m]
    scan = {n: p for m, n, p in flops if "__sdf" in m}
    by_scd = defaultdict(list)
    for n, p in scan.items():
        by_scd[p["SCD"]].append(n)
    # buffers and inverters: input net -> [(output net, inverts)]
    bufs = defaultdict(list)
    for m, n, p in cells:
        g = re.search(r"__(c?l?k?buf|buf|dlygate|clkdlybuf|inv|clkinv)\w*_\d+$", m)
        if g and "A" in p:
            outp = p.get("X") or p.get("Y")
            if outp:
                bufs[p["A"]].append((outp, "inv" in g.group(1)))
    # nets that reach an output port (directly, or through an assign)
    out_of = {}
    for name, kind in ports.items():
        if kind == "output":
            out_of[name] = name
            if name in assigns:
                out_of[assigns[name]] = name

    errors = []
    if plain:
        errors.append(f"{len(plain)} flops are not scan flops, e.g. {plain[0]}")

    # scan enable: each SCE back through the buffer tree to its root, which
    # must be one input port, reached without inversion
    drv = {o: (a, i) for a, lst in bufs.items() for o, i in lst}

    def root(net):
        inv = False
        for _ in range(64):
            if net not in drv:
                break
            net, i = drv[net]
            inv ^= i
        return net, inv

    roots = {root(p["SCE"]) for p in scan.values()}
    ses = {r for r, _ in roots}
    if len(roots) != 1 or ports.get(next(iter(ses))) != "input":
        errors.append(f"scan enables from {len(roots)} roots, e.g. {sorted(roots)[:4]}")

    def reach(net, inv=False, depth=0):
        """(kind, target, inverted) for each SCD or output reached from net."""
        found = [("scd", f, inv) for f in by_scd.get(net, [])]
        so = out_of.get(net)
        if so is None and ports.get(net.split("[")[0]) == "output":
            so = net                                # a bit of an output bus
        if so is not None:
            found.append(("out", so, inv))
        # buffers per hop: the SoC's 6 mm die needs 13 to 16 (fanout trees plus
        # hold buffers); 8 dropped 243 flops off chain 0. Only a loop guard.
        if depth < 64:
            for o, i in bufs.get(net, []):
                found += reach(o, inv ^ i, depth + 1)
        return found

    chains, seen = [], set()
    for si in sorted((p for p, k in ports.items() if k == "input" and p.startswith("scan_in_")),
                     key=lambda s: int(s.rsplit("_", 1)[1])):
        net, chain, inv, so = si, [], False, None
        while True:
            r = reach(net, inv)
            scds = [x for x in r if x[0] == "scd"]
            if len(scds) > 1:
                errors.append(f"{si}: net {net} reaches {len(scds)} scan inputs")
                break
            if not scds:
                outs = [x for x in r if x[0] == "out"]
                if outs:                            # the nearest: fewest buffers
                    so, inv = outs[0][1], outs[0][2]
                else:
                    errors.append(f"{si}: chain ends on net {net}, reaching {len(outs)} outputs")
                break
            _, f, inv = scds[0]
            if f in seen:
                errors.append(f"{si}: {f} already on a chain")
                break
            seen.add(f)
            chain.append(f)
            net = scan[f]["Q"]
        chains.append({"scan_in": si, "scan_out": so, "inverted": inv, "flops": chain})
        print(f"{si:>10} -> {str(so):<24} {len(chain)} flops{', inverted' if inv else ''}")
    missing = set(scan) - seen
    if missing:
        errors.append(f"{len(missing)} scan flops on no chain, e.g. {sorted(missing)[0]}")
    print(f"chains {len(chains)}, scan flops {len(scan)}, on chains {len(seen)}, "
          f"longest {max((len(c['flops']) for c in chains), default=0)}, scan enable {sorted(ses)}")
    if out_json:
        json.dump({"scan_enable": sorted(ses)[0] if ses else None, "chains": chains}, open(out_json, "w"))
    for e in errors:
        print("ERROR:", e)
    sys.exit(1 if errors or not chains else 0)


if __name__ == "__main__":
    main()
