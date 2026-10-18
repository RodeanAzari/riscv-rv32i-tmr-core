#!/usr/bin/env python3
"""Summarise a LibreLane run (make asic) for docs/reports/.

Usage: scripts/asic_summary.py <run dir> <out dir>

Writes <out dir>/summary_asic.txt from the run's final metrics, copies the
post-PnR STA summary (sta_asic.rpt) and the manufacturability report
(manufacturability_asic.rpt). Every number is read from the run's files.
LibreLane's own layout render is not copied: the top metal hides the cells.
The layout screenshots in docs/img/asic/ are taken by hand in KLayout.
"""

import glob
import json
import os
import shutil
import sys


def step_dir(run, name):
    """The last directory of a step, e.g. 'openroad-stapostpnr'."""
    dirs = sorted(glob.glob(os.path.join(run, f"*-{name}")),
                  key=lambda d: int(os.path.basename(d).split("-")[0]))
    if not dirs:
        sys.exit(f"{run}: no {name} step")
    return dirs[-1]


def worst(m, key):
    """The worst corner's value of a per-corner slack metric, and the corner."""
    per = {k.split("corner:")[1]: v for k, v in m.items() if k.startswith(key + "__corner:")}
    corner = min(per, key=per.get)
    return per[corner], corner


def fmax(period, slack):
    return 1000.0 / (period - slack)


def main(run, out_dir):
    m = json.load(open(os.path.join(run, "final", "metrics.json")))
    # The flow's configuration, merged from the steps' copies: resolved.json is
    # rewritten when the run is opened in a viewer (--last-run --flow openinklayout).
    cfg = {}
    for f in glob.glob(os.path.join(run, "*-*", "config.json")):
        cfg.update(json.load(open(f)))
    pre = json.load(open(os.path.join(step_dir(run, "openroad-staprepnr"), "state_out.json")))["metrics"]
    period = float(cfg["CLOCK_PERIOD"])

    setup, setup_c = worst(m, "timing__setup__ws")
    r2r, r2r_c = worst(m, "timing__setup_r2r__ws")
    hold, hold_c = worst(m, "timing__hold__ws")
    pre_setup, pre_c = worst(pre, "timing__setup__ws")
    pre_r2r, pre_r2r_c = worst(pre, "timing__setup_r2r__ws")
    tt = cfg["DEFAULT_CORNER"]

    fill = m["design__instance__count__class:fill_cell"]
    tap = m["design__instance__count__class:tap_cell"]
    lines = [
        f"=== {cfg['DESIGN_NAME']}, LibreLane RTL-to-GDSII ===",
        f"flow            LibreLane {cfg['meta']['librelane_version']}, classic",
        f"PDK             {cfg['PDK']} ({cfg['STD_CELL_LIBRARY']})",
        f"constraint      {period:.3f} ns ({1000 / period:.1f} MHz), I/O delay {cfg['IO_DELAY_CONSTRAINT']}% of the period",
        f"PnR corners     {', '.join(cfg['PNR_CORNERS'] or [tt])}",
        f"signoff corners {len(cfg['STA_CORNERS'])} (ss/tt/ff x min/nom/max parasitics)",
        "",
        "Timing, post-layout (worst corner of all signoff corners)",
        f"  setup WS        {setup:+.3f} ns  ({setup_c})  -> Fmax {fmax(period, setup):.1f} MHz, I/O paths included",
        f"  reg-to-reg WS   {r2r:+.3f} ns  ({r2r_c})  -> Fmax {fmax(period, r2r):.1f} MHz",
        f"  hold WS         {hold:+.3f} ns  ({hold_c})",
        f"  setup / hold violations   {m['timing__setup_vio__count']} / {m['timing__hold_vio__count']}",
        f"  typical ({tt}): setup WS {m['timing__setup__ws__corner:' + tt]:+.3f} ns"
        f" -> Fmax {fmax(period, m['timing__setup__ws__corner:' + tt]):.1f} MHz",
        "Timing, pre-layout estimate (synthesised netlist, before placement)",
        f"  setup WS        {pre_setup:+.3f} ns  ({pre_c})  -> Fmax {fmax(period, pre_setup):.1f} MHz",
        f"  reg-to-reg WS   {pre_r2r:+.3f} ns  ({pre_r2r_c})  -> Fmax {fmax(period, pre_r2r):.1f} MHz",
        "",
        "Electrical rule checks (all corners)",
        f"  max slew / max cap / max fanout violations  "
        f"{m['design__max_slew_violation__count']} / {m['design__max_cap_violation__count']}"
        f" / {m['design__max_fanout_violation__count']}",
        "",
        "Area",
        f"  die             {m['design__die__area']:.0f} um^2",
        f"  core            {m['design__core__area']:.0f} um^2",
        f"  standard cells  {m['design__instance__area__stdcell']:.0f} um^2"
        f" ({100 * m['design__instance__utilization']:.1f}% of the core)",
        f"  of which flops  {m['design__instance__area__class:sequential_cell']:.0f} um^2"
        f" ({m['design__instance__count__class:sequential_cell']} cells)",
        "",
        "Cells",
        f"  standard cells  {m['design__instance__count__stdcell']}"
        f" ({tap} tap cells among them; {fill} fill cells besides)",
        f"  combinational   {m['design__instance__count__class:multi_input_combinational_cell']}",
        f"  sequential      {m['design__instance__count__class:sequential_cell']}",
        f"  timing repair buffers {m['design__instance__count__class:timing_repair_buffer']}"
        f" (hold {m['design__instance__count__hold_buffer']}, setup {m['design__instance__count__setup_buffer']})",
        f"  clock buffers   {m['design__instance__count__class:clock_buffer']}",
        "",
        f"Power ({tt}, vectorless default activity)",
        f"  total           {1000 * m['power__total']:.3f} mW"
        f" (internal {1000 * m['power__internal__total']:.3f},"
        f" switching {1000 * m['power__switching__total']:.3f},"
        f" leakage {1e6 * m['power__leakage__total']:.3f} uW)",
        "",
        "Signoff",
        f"  Magic DRC {m['magic__drc_error__count']}, KLayout DRC {m['klayout__drc_error__count']},"
        f" LVS errors {m['design__lvs_error__count']}, antenna violations {m['route__antenna_violation__count']},"
        f" GDS XOR differences {m['design__xor_difference__count']}",
        f"  routed wirelength {m['route__wirelength']:.0f} um, IR drop worst {1000 * m['ir__drop__worst']:.2f} mV",
    ]
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "summary_asic.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    shutil.copy(os.path.join(step_dir(run, "openroad-stapostpnr"), "summary.rpt"),
                os.path.join(out_dir, "sta_asic.rpt"))
    shutil.copy(os.path.join(step_dir(run, "misc-reportmanufacturability"), "manufacturability.rpt"),
                os.path.join(out_dir, "manufacturability_asic.rpt"))
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
