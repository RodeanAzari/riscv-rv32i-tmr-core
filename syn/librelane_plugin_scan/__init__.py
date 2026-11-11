"""Scan chain insertion for LibreLane (buildplan §6.5).

LibreLane 3.0.16 has no DFT step; the OpenROAD it ships has the `dft`
module. Two steps, substituted into the Classic flow by the config's
`meta.substituting_steps` (`make asic` puts this directory on PYTHONPATH,
where LibreLane discovers `librelane_plugin_*` modules):

  Scan.Replace  after OpenROAD.Floorplan: every flop becomes its scan
                equivalent (`scan_replace`, sky130 dfxtp -> sdfxtp), scan
                enable and scan in tied off until the chains exist.
  Scan.Stitch   before OpenROAD.IOPlacement (after the IO-less global
                placement, which the chain order follows): `execute_dft_plan`
                stitches the chains and adds their ports (scan_enable_1,
                scan_in_<n>, scan_out_<n>), which IOPlacement then places.

Each reports in its step log; Scan.Stitch's
`report_dft_plan -verbose` lists every chain and its flops.
"""

import os

from librelane.config import Variable
from librelane.steps import Step
from librelane.steps.openroad import OpenROADStep

HERE = os.path.dirname(os.path.abspath(__file__))


@Step.factory.register()
class ScanReplace(OpenROADStep):
    """Replace every flop with its scan equivalent."""

    id = "Scan.Replace"
    name = "Scan Replace"

    def get_script_path(self):
        return os.path.join(HERE, "scan_replace.tcl")


@Step.factory.register()
class ScanStitch(OpenROADStep):
    """Stitch the scan flops into chains and add their ports."""

    id = "Scan.Stitch"
    name = "Scan Stitch"

    config_vars = OpenROADStep.config_vars + [
        Variable(
            "SCAN_MAX_CHAINS",
            int,
            "Number of scan chains (each a scan-in and a scan-out pin).",
            default=8,
        ),
    ]

    def get_script_path(self):
        return os.path.join(HERE, "scan_stitch.tcl")
