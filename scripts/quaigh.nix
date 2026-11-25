# Quaigh 0.0.6 as Fault 0.9.4 pins it (same flake, Cargo.lock, rustc and
# kissat), with quaigh-sparse-detections.patch applied. Built with no patch
# this expression gives the stock store path, so the patch is the only change.
# Used by make asic SCAN=1 (scripts/scan_coverage.py).
let
  q = (builtins.getFlake "github:AUCOHL/Fault/0.9.4").inputs.quaigh;
  pkgs = import q.inputs.nixpkgs { system = "x86_64-linux"; };
  src = pkgs.applyPatches {
    name = "quaigh-sparse-src";
    src = q;
    patches = [ ./quaigh-sparse-detections.patch ];
  };
  flake = (import "${src}/flake.nix").outputs {
    self = src;
    nixpkgs = q.inputs.nixpkgs;
    cargo2nix = q.inputs.cargo2nix;
  };
in flake.packages.x86_64-linux.quaigh
