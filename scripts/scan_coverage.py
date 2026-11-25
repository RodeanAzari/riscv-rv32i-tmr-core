#!/usr/bin/env python3
"""Stuck-at test coverage of a scanned LibreLane netlist (buildplan §6.5).

Flow (docs/design-notes.md, "Fault, tried 2026-11-09"): this script
prepares the netlist, Fault cuts the flops (`fault cut`) and converts the
result to a .bench (`nl2bench`), and Quaigh generates the patterns and
counts the faults (`quaigh atpg`). Fault's own ATPG and coverage are not
used (README, "Scan test coverage").

Preparation, because `fault cut` keeps only a flop's D and Q:
- every scan flop (sdfxtp) becomes the mux it contains (mux2: A0 = D,
  A1 = SCD, S = SCE) feeding a plain flop, so the scan muxes' faults are
  counted; SCE is then an input like any other (full scan, capture and
  shift both reachable). A scan flop with an asynchronous set (sdfsbp, the
  SoC's reset synchronizer) is converted the same way and its SET_B is
  dropped: scan capture cannot test an asynchronous set, so the logic
  driving it stays in the fault list as undetected (counted, not hidden);
- cells with no logic (decap, fill, tap, antenna diode) are dropped;
- each SRAM macro is cut like a flop: its data and control inputs become
  outputs (observed), its read data becomes inputs (controlled). That is
  the memory boundary a bypass wrapper would give. The report states that
  assumption and how much of the logic it decides ("exposed").

Usage: scripts/scan_coverage.py <netlist.nl.v> <top> <liberty> <workdir>
Tools from $FAULT, $NL2BENCH, $QUAIGH (default: on PATH). Writes
<workdir>/coverage.txt and prints it; exits nonzero on any failure.
"""

import os
import re
import subprocess
import sys

PHYSICAL = re.compile(r"__(decap|fill|tapvpwrvgnd|diode)_\d+$")
SCAN_FF = re.compile(r"^sky130_fd_sc_hd__sdf(xtp|sbp)_\d+$")
SRAM = re.compile(r"^sky130_sram_")
# SRAM pins: inputs (observed) and outputs (controlled); clocks are left to
# the scan clock, as the flops' are.
SRAM_OUT = {"dout0", "dout1"}
SRAM_CLK = {"clk0", "clk1"}
INST = re.compile(r"\b(sky130_\w+)\s+(\\?\S+)\s*\((.*?)\);", re.S)
PIN = re.compile(r"\.(\w+)\s*\(([^()]*)\)")

# fault cut: flops by D/Q (CLK, and dfstp's SET_B, are dropped by cut)
SCL_CONFIG = """dffMatches:
  - name: "sky130_fd_sc_hd__dfxtp_*,sky130_fd_sc_hd__dfstp_*"
    clk: CLK
    d: D
    q: Q
"""


def net(s):
    """A net or instance name to write back: an escaped identifier (\\a.b[3])
    ends at whitespace, so it keeps one trailing space."""
    s = s.strip()
    return s + " " if s.startswith("\\") else s


def bits(conn):
    """A pin connection as a list of nets, MSB first."""
    conn = conn.strip()
    if conn.startswith("{"):
        return [net(b) for b in conn[1:-1].split(",") if b.strip()]
    return [net(conn)] if conn else []


def prepare(src, dst):
    text = open(src).read()
    stats = {"physical": 0, "scan_ff": 0, "async_set": 0, "sram": 0, "sram_obs": 0, "sram_ctl": 0}
    new_wires, new_ports, new_decls, assigns = [], [], [], []

    def rewrite(m):
        master, name, body = m.group(1), m.group(2), m.group(3)
        if PHYSICAL.search(master):
            stats["physical"] += 1
            return ""
        pins = dict(PIN.findall(body))
        if SCAN_FF.match(master):
            stats["scan_ff"] += 1
            k = stats["scan_ff"]
            mid = f"scancov_d_{k}"
            new_wires.append(mid)
            for p in ("D", "SCD", "SCE", "CLK", "Q"):
                if p not in pins:
                    raise SystemExit(f"{name}: scan flop without {p}")
            if pins.get("Q_N", "").strip():
                raise SystemExit(f"{name}: Q_N is connected; only Q is converted")
            if "SET_B" in pins:
                stats["async_set"] += 1
            mux = net(name.strip() + "_scanmux")
            return (f"sky130_fd_sc_hd__mux2_1 {mux} (.A0({net(pins['D'])}), "
                    f".A1({net(pins['SCD'])}), .S({net(pins['SCE'])}), .X({mid}));\n"
                    f"  sky130_fd_sc_hd__dfxtp_1 {net(name)} (.CLK({net(pins['CLK'])}), "
                    f".D({mid}), .Q({net(pins['Q'])}));")
        if SRAM.match(master):
            stats["sram"] += 1
            k = stats["sram"]
            for p, conn in pins.items():
                if p in SRAM_CLK:
                    continue
                nets = bits(conn)
                for i, n in enumerate(reversed(nets)):    # LSB first
                    port = f"sram{k}_{p}_{i}"
                    new_ports.append(port)
                    if p in SRAM_OUT:
                        stats["sram_ctl"] += 1
                        new_decls.append(f"  input {port};")
                        assigns.append(f"  assign {n} = {port};")
                    else:
                        stats["sram_obs"] += 1
                        new_decls.append(f"  output {port};")
                        assigns.append(f"  assign {port} = {n};")
            return ""
        return m.group(0)

    body = INST.sub(rewrite, text)
    # new ports into the header, declarations and wires after it
    head_end = body.index(");") + 2
    header, rest = body[:head_end], body[head_end:]
    if new_ports:
        header = header[:-2] + ",\n    " + ",\n    ".join(new_ports) + ");"
    end = rest.rindex("endmodule")
    # assigns go last (after every wire is declared), declarations first
    decls = "\n".join(new_decls + [f"  wire {w};" for w in new_wires])
    rest = "\n" + decls + rest[:end] + "\n".join(assigns) + "\n" + rest[end:]
    with open(dst, "w") as f:
        f.write(header + rest)
    return stats


def run(cmd, log):
    with open(log, "w") as f:
        r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        sys.stderr.write(open(log).read()[-3000:])
        raise SystemExit(f"failed ({r.returncode}): {' '.join(cmd)}; log {log}")
    return open(log).read()


def exposure(bench):
    """Uncollapsed stuck-at faults (two per gate pin) on logic the SRAM
    boundary assumption decides: gates in the fan-out of an SRAM read bit,
    and gates observable only through SRAM inputs. Returns (exposed, total)."""
    gates, outs, sram_in = {}, [], []
    for line in open(bench):
        line = line.strip()
        if line.startswith("INPUT("):
            if line[6:-1].startswith("sram"):
                sram_in.append(line[6:-1])
        elif line.startswith("OUTPUT("):
            outs.append(line[7:-1])
        elif "=" in line:
            lhs, rhs = line.split("=", 1)
            args = rhs[rhs.index("(") + 1:rhs.rindex(")")]
            gates[lhs.strip()] = [a.strip() for a in args.split(",") if a.strip()]
    fanout = {}
    for g, ins in gates.items():
        for i in ins:
            fanout.setdefault(i, []).append(g)

    def reach(starts, step):
        seen, todo = set(), list(starts)
        while todo:
            n = todo.pop()
            for m in step(n):
                if m not in seen:
                    seen.add(m)
                    todo.append(m)
        return seen

    reads = reach(sram_in, lambda n: fanout.get(n, []))
    seen_by_logic = reach([o for o in outs if not o.startswith("sram")] , lambda n: gates.get(n, []))
    seen_by_logic |= {o for o in outs if not o.startswith("sram")}
    exposed = {g for g in gates if g in reads or g not in seen_by_logic}
    faults = lambda g: 2 * (len(gates[g]) + 1)
    return sum(faults(g) for g in exposed), sum(faults(g) for g in gates)


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    netlist, top, lib, work = sys.argv[1:]
    os.makedirs(work, exist_ok=True)
    fault = os.environ.get("FAULT", "fault")
    nl2bench = os.environ.get("NL2BENCH", "nl2bench")
    quaigh = os.environ.get("QUAIGH", "quaigh")

    prep = os.path.join(work, f"{top}.prep.nl.v")
    stats = prepare(netlist, prep)
    if stats["scan_ff"] == 0:
        raise SystemExit("no scan flops in the netlist: run make asic SCAN=1")
    cfg = os.path.join(work, "scl.yaml")
    open(cfg, "w").write(SCL_CONFIG)
    cut = os.path.join(work, f"{top}.cut.v")
    run([fault, "cut", "--sclConfig", cfg, "--clock", "clk_i", "--reset", "rst_i",
         "-o", cut, prep], os.path.join(work, "cut.log"))
    bench = os.path.join(work, f"{top}.bench")
    run([nl2bench, "-l", lib, "-o", bench, cut], os.path.join(work, "nl2bench.log"))
    show = run([quaigh, "show", bench], os.path.join(work, "show.log"))
    atpg = run([quaigh, "atpg", bench, "-o", os.path.join(work, "patterns.txt")],
               os.path.join(work, "atpg.log"))
    net = re.search(r"Analyzing network with (\d+) inputs, (\d+) outputs, (\d+) gates, "
                    r"(\d+) possible faults, (\d+) unique faults", atpg)
    res = re.search(r"Kept (\d+) patterns, detecting (\d+)/(\d+) faults", atpg)
    if not (net and res):
        raise SystemExit(f"no result line in {work}/atpg.log")
    pats, det, tot = (int(x) for x in res.groups())
    # proven untestable: SAT found no pattern (Quaigh's final "unobservable=")
    unobs = re.findall(r"unobservable=(\d+)", atpg)
    if not unobs:
        raise SystemExit(f"no unobservable count in {work}/atpg.log")
    unt = int(unobs[-1])
    lines = [
        f"# Stuck-at test coverage of {os.path.basename(netlist)} (scripts/scan_coverage.py):",
        "# fault cut + nl2bench (Fault 0.9.4), quaigh atpg (0.0.6 with",
        "# scripts/quaigh-sparse-detections.patch: memory only, same patterns), full scan.",
        "",
        f"scan flops (split into mux2 + dfxtp): {stats['scan_ff']}",
    ]
    if stats["async_set"]:
        lines += [f"  of them with an asynchronous set:  {stats['async_set']}"
                  " (SET_B dropped: its driving logic is untestable by scan, counted)"]
    lines += [
        f"cells without logic dropped:         {stats['physical']}",
        f"network: {net.group(1)} inputs, {net.group(2)} outputs, {net.group(3)} gates, "
        f"{net.group(4)} faults, {net.group(5)} unique (collapsed)",
        f"patterns: {pats}",
        f"coverage: {det}/{tot} unique faults detected = {100.0 * det / tot:.2f}%"
        " (every undetected fault counts against it)",
        f"  undetected: {unt} proven untestable (no pattern exists),"
        f" {tot - det - unt} unresolved (a SAT pattern that the",
        "  fault simulation then did not confirm; varies with the seed)",
    ]
    if stats["sram"]:
        exp, allf = exposure(bench)
        lines += [
            "",
            f"SRAM macros: {stats['sram']}, cut at their boundary: {stats['sram_ctl']} read-data bits",
            f"as inputs (controlled), {stats['sram_obs']} input bits as outputs (observed).",
            "ASSUMPTION: that boundary is what a bypass wrapper would give; this chip has",
            "none, so in a scan test the read data is unknown. Logic it decides (fan-out",
            "of a read bit, or observable only at an SRAM input):",
            f"exposed: {exp}/{allf} uncollapsed faults = {100.0 * exp / allf:.2f}%",
            "(counted by this script from the .bench, two per gate pin: not Quaigh's",
            "own fault count above, which can differ slightly)",
        ]
    report = "\n".join(lines) + "\n"
    open(os.path.join(work, "coverage.txt"), "w").write(report)
    print(report, end="")


if __name__ == "__main__":
    main()
