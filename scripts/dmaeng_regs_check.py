#!/usr/bin/env python3
"""The DMA register package and header must be what spec/dmaeng.yaml generates.

The RTL imports sw/dma-engine/rtl/dmaeng_pkg.sv and the driver and model read
sw/dma-engine/include/dmaeng_regs.h, both committed in DMA-Engine's repo. This
runs DMA-Engine's own generator (scripts/gen-regs.py) on a copy of its spec in
a temporary directory, never in the submodule, and requires both generated
files to match the committed ones byte for byte. Needs PyYAML.
"""

import filecmp
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DMAENG = Path(__file__).resolve().parents[1] / "sw" / "dma-engine"
CHECKED = ["rtl/dmaeng_pkg.sv", "include/dmaeng_regs.h"]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for d in ("spec", "scripts"):
            shutil.copytree(DMAENG / d, tmp / d)
        subprocess.run([sys.executable, str(tmp / "scripts" / "gen-regs.py")],
                       check=True, cwd=tmp)
        bad = [f for f in CHECKED
               if not filecmp.cmp(tmp / f, DMAENG / f, shallow=False)]
    for f in CHECKED:
        print(f"{'FAIL' if f in bad else 'PASS'}: sw/dma-engine/{f} "
              f"{'differs from' if f in bad else 'matches'} spec/dmaeng.yaml")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
