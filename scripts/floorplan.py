#!/usr/bin/env python3
"""Draw the routed board design as a zoomable SVG floorplan.

Usage: scripts/floorplan.py <export dir> <out.svg> [<core.svg>]

Reads what syn/floorplan_export.tcl wrote from post_route.dcp: the device's
tiles, every placed cell and the routing nodes of every signal net. Draws the
die on Vivado's tile grid (columns of logic, block RAM and DSP; clock regions
outlined), each cell at its real site and BEL coloured by module, each net's
wires coloured by the module that drives it, and the worst setup path on top
in yellow. The optional second file is the same drawing cropped to the
logic, for a README that should not open on a mostly empty chip.

A wire is drawn as straight lines between the tiles where it meets the rest
of its route, not with the switch-level geometry inside a tile. The clock and
power nets are not drawn.
"""
import csv
import html
import re
import sys

U = 10                                   # pixels per tile-grid unit

# Leaf cells by hierarchy, most specific first (as in syn/gui_view.tcl).
# A single core is coloured by pipeline module; a TMR build (make impl
# TMR=1) by copy, so the three copies and the voter show where they landed.
CORE = "u_soc/g_cpu.u_core/"
SOC_REST = [
    ("u_soc/u_ram/",            "#f0f0f0", "32 KiB RAM (block RAM)"),
    ("u_soc/u_uart_tx/",        "#ff3030", "UART transmitter"),
    ("u_soc/u_uart_rx/",        "#ff9090", "UART receiver"),
    ("",                        "#a0a0a0", "SoC glue and board top: I/O registers, clocking, reset"),
]
MODULES_CORE = [
    (CORE + "u_alu/",     "#ff8000", "ALU"),
    (CORE + "u_branch/",  "#ff00ff", "branch compare + target"),
    (CORE + "u_regfile/", "#00c8ff", "register file (LUTRAM)"),
    (CORE,                "#00e000", "rest of core: decode, hazards, pipeline registers"),
] + SOC_REST
MODULES_TMR = [
    (CORE + "u_core_a/",           "#ff8000", "core copy A"),
    (CORE + "g_other[1].u_core/",  "#00e000", "core copy B"),
    (CORE + "g_other[2].u_core/",  "#00c8ff", "core copy C"),
    (CORE,                         "#ff00ff", "voter + mismatch counter"),
] + SOC_REST
MODULES = MODULES_CORE
WORST = "#ffe000"

# Background by tile type: (pattern, fill, rows tall).
TILE_STYLE = [
    (r"^CLBLM_",      "#2c3138", 1),
    (r"^CLBLL_",      "#262a30", 1),
    (r"^BRAM_[LR]$",  "#1d3550", 5),
    (r"^DSP_[LR]$",   "#3a2448", 5),
    (r"^[LR]IOB33",   "#4a3a22", 1),
    (r"^CMT_TOP_",    "#1f4030", 1),
]


def read(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def module(name):
    for i, (prefix, colour, _) in enumerate(MODULES):
        if name.startswith(prefix):
            return i, colour
    return len(MODULES) - 1, MODULES[-1][1]


def main():
    d, out = sys.argv[1], sys.argv[2]
    core_out = sys.argv[3] if len(sys.argv) > 3 else None
    tiles = {r["name"]: (int(r["x"]), int(r["y"]), r["type"])
             for r in read(f"{d}/tiles.tsv")}
    cells = read(f"{d}/cells.tsv")
    global MODULES
    tmr = any(c["name"].startswith(CORE + "u_core_a/") for c in cells)
    MODULES = MODULES_TMR if tmr else MODULES_CORE
    nets = read(f"{d}/nets.tsv")
    worst = read(f"{d}/worst_path.tsv")
    slack = next(r["name"] for r in worst if r["kind"] == "slack")
    worst_cells = {r["name"] for r in worst if r["kind"] == "cell"}
    worst_nets = {r["name"] for r in worst if r["kind"] == "net"}
    w = (max(t[0] for t in tiles.values()) + 1) * U
    h = (max(t[1] for t in tiles.values()) + 1) * U
    head = 110                           # title, three legend rows, caption
    svg = []
    add = svg.append

    # ---- device background ----
    add('<g id="device">')
    for x, y, typ in tiles.values():
        for pat, fill, rows in TILE_STYLE:
            if re.match(pat, typ):
                add(f'<rect x="{x*U+.5}" y="{(y-rows+1)*U+.5}" width="{U-1}" '
                    f'height="{rows*U-1}" fill="{fill}"/>')
                break
    add("</g>")

    add('<g id="clock-regions" fill="none" stroke="#5a6470" stroke-width="2">')
    for r in read(f"{d}/clock_regions.tsv"):
        (x0, y0, _), (x1, y1, _) = tiles[r["top_left"]], tiles[r["bottom_right"]]
        xa, xb = sorted((x0, x1))
        ya, yb = sorted((y0, y1))
        add(f'<rect x="{xa*U}" y="{ya*U}" width="{(xb-xa+1)*U}" height="{(yb-ya+1)*U}"/>')
        add(f'<text x="{xa*U+8}" y="{ya*U+26}" fill="#5a6470" stroke="none" '
            f'font-size="22" font-family="sans-serif">{r["name"]}</text>')
    add("</g>")

    # ---- wires, by driving module; the worst path's last ----
    by_mod = {}
    worst_lines = []
    for n in nets:
        pts = []
        for seg in n["segments"].split():
            ts = [tiles[t] for t in seg.split(",")]
            ts.sort(key=lambda t: (t[0], t[1]))
            pts.append(" ".join(f"{t[0]*U+U/2},{t[1]*U+U/2}" for t in ts))
        target = worst_lines if n["name"] in worst_nets else \
            by_mod.setdefault(module(n["driver"])[0], [])
        target.extend(pts)
    add('<g id="wires" fill="none" stroke-width="0.7" stroke-opacity="0.55" '
        'stroke-linecap="round">')
    for i, lines in sorted(by_mod.items()):
        add(f'<g stroke="{MODULES[i][1]}">')
        add("".join(f'<polyline points="{p}"/>' for p in lines))
        add("</g>")
    add("</g>")

    # ---- cells: a slice is half a CLB tile; LUTs left, flops right, A at
    # the bottom as in Vivado's device view ----
    counts = [0] * len(MODULES)
    box = [w, h, 0, 0]
    add('<g id="cells">')
    for c in cells:
        x, y, typ = tiles[c["tile"]]
        i, colour = module(c["name"])
        counts[i] += 1
        stroke = f' stroke="{WORST}" stroke-width="1"' if c["name"] in worst_cells else ""
        title = f'<title>{html.escape(c["name"])} ({c["ref"]}, {c["site"]} {c["bel"]})</title>'
        bel = c["bel"].split(".")[-1]
        m = re.match(r"SLICE_X(\d+)Y\d+", c["site"])
        if m and bel[0] in "ABCD":
            sx = x * U + (int(m.group(1)) % 2) * U / 2
            row = "DCBA".index(bel[0])
            kind = 1 if "FF" in bel else 0
            cx, cy, cw, ch = sx + kind * U / 4, y * U + row * U / 4, U / 4, U / 4
        elif typ.startswith("BRAM"):
            cx, cy, cw, ch = x * U, (y - 4) * U, U, 5 * U
        else:                            # carry chain, IO, clocking: whole tile
            cx, cy, cw, ch = x * U, y * U, U, U
        add(f'<rect x="{cx+.15:.2f}" y="{cy+.15:.2f}" width="{cw-.3:.2f}" '
            f'height="{ch-.3:.2f}" fill="{colour}"{stroke}>{title}</rect>')
        if i < len(MODULES) - 1:          # the crop frames the SoC, not the board top
            box = [min(box[0], cx), min(box[1], cy), max(box[2], cx + cw), max(box[3], cy + ch)]
    add("</g>")

    add(f'<g id="worst-path" fill="none" stroke="{WORST}" stroke-width="1.6" '
        'stroke-linecap="round">')
    add("".join(f'<polyline points="{p}"/>' for p in worst_lines))
    add("</g>")

    # ---- title and legend (above the die, in its own band) ----
    def legend(x0, y0, scale):
        g = [f'<g font-family="sans-serif" font-size="{14*scale:.1f}" fill="#d8dde3">',
             f'<text x="{x0}" y="{y0+16*scale}" font-size="{18*scale:.1f}" font-weight="bold">'
             f'RV32I {"TMR core (three voted copies)" if MODULES is MODULES_TMR else "core"} '
             f'on the Arty A7-100T (xc7a100tcsg324-1): placed and routed, '
             f'100 MHz, worst slack +{float(slack):.3f} ns</text>']
        items = [(c, f"{l} ({n})") for (_, c, l), n in zip(MODULES, counts)] + \
                [(WORST, "worst setup path")]
        for k, (colour, label) in enumerate(items):
            lx = x0 + (k % 4) * 330 * scale
            ly = y0 + (36 + (k // 4) * 20) * scale
            g.append(f'<rect x="{lx}" y="{ly}" width="{12*scale}" height="{12*scale}" fill="{colour}"/>'
                     f'<text x="{lx+18*scale}" y="{ly+11*scale}">{html.escape(label)}</text>')
        rows = (len(items) + 3) // 4
        g.append(f'<text x="{x0}" y="{y0+(36+rows*20+14)*scale}" fill="#8a939d" font-size="{11*scale:.1f}">'
                 'Generated from post_route.dcp (syn/floorplan_export.tcl, scripts/floorplan.py). '
                 'Cell counts are placed leaf cells. Wires drawn tile to tile; clock and power nets omitted.'
                 '</text></g>')
        return "".join(g)

    def write(path, vx, vy, vw, vh, scale):
        band = head * scale + 30 * scale
        with open(path, "w") as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" '
                    f'viewBox="{vx:.0f} {vy-band:.0f} {vw:.0f} {vh+band:.0f}" '
                    f'width="{vw/scale:.0f}" height="{(vh+band)/scale:.0f}">\n')
            f.write(f'<rect x="{vx}" y="{vy-band}" width="{vw}" height="{vh+band}" fill="#14171b"/>\n')
            f.write(f'<clipPath id="die"><rect x="{vx}" y="{vy}" width="{vw}" height="{vh}"/></clipPath>\n')
            f.write('<g clip-path="url(#die)">\n' + "\n".join(svg) + "\n</g>\n")
            f.write(legend(vx + 10 * scale, vy - band + 8 * scale, scale) + "\n")
            f.write("</svg>\n")

    write(out, 0, 0, w, h, w / 1400)
    if core_out:
        m = 6 * U
        vx, vy = box[0] - m, box[1] - m
        vw, vh = box[2] - box[0] + 2 * m, box[3] - box[1] + 2 * m
        write(core_out, vx, vy, vw, vh, vw / 1400)
    print(f"{out}: {len(cells)} cells, {sum(len(n['segments'].split()) for n in nets)} "
          f"wire segments; worst path {len(worst_cells)} cells, slack {slack} ns")


if __name__ == "__main__":
    main()
