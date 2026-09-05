#!/usr/bin/env bash
# Run a command with Vivado's environment, scoped to that one process.
#
#   scripts/setup-vivado-env.sh vivado -mode batch -source syn/synth_ooc.tcl
#
# settings64.sh is deliberately NOT sourced from ~/.bashrc: it prepends
# Vivado's bundled libstdc++/libssl/libcurl to LD_LIBRARY_PATH, which shadows
# the system versions and breaks git, curl and python in every shell. Keeping
# it inside a wrapper means only Vivado sees it.
#
# Override the install with VIVADO_SETTINGS=/path/to/settings64.sh.
#
# See docs/vivado-setup.md for why each of these three fixups exists.
set -eo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

# Layout differs by release: ~/Xilinx/<ver>/Vivado/ in 2026.1+,
# ~/Xilinx/Vivado/<ver>/ before that. Take the newest of either.
# ls exits nonzero when one of the two globs does not match, which under
# `set -e` would kill this script before it could report anything useful.
if [ -z "$VIVADO_SETTINGS" ]; then
    VIVADO_SETTINGS=$(ls -d "$HOME"/[Xx]ilinx/*/Vivado/settings64.sh \
                            "$HOME"/[Xx]ilinx/Vivado/*/settings64.sh 2>/dev/null |
                      sort -V | tail -1) || true
fi

if [ ! -f "$VIVADO_SETTINGS" ]; then
    echo "error: no Vivado settings64.sh found under ~/Xilinx" >&2
    echo "       set VIVADO_SETTINGS, or see docs/vivado-setup.md section 1" >&2
    exit 1
fi

# Vivado's Tcl extensions link against ncurses 5, which Ubuntu 26.04 does not
# package. Without these the tool does not fail cleanly -- batch runs hang at
# 0% CPU with no output. Report it rather than writing into ~/.local silently.
COMPAT="$HOME/.local/lib/vivado-compat"
for lib in libncurses.so.5 libtinfo.so.5; do
    if [ ! -e "$COMPAT/$lib" ]; then
        cat >&2 <<MSG
error: $COMPAT/$lib is missing.
       Vivado needs ncurses 5; this distro ships only ncurses 6. Create the
       compat symlinks once:

         mkdir -p $COMPAT && cd $COMPAT
         ln -sf /lib/x86_64-linux-gnu/libncursesw.so.6 libncurses.so.5
         ln -sf /lib/x86_64-linux-gnu/libncursesw.so.6 libncursesw.so.5
         ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6    libtinfo.so.5
MSG
        exit 1
    fi
done

# 2026.1 forced LC_ALL=en_US.UTF-8 and crashed without it. 2025.2 does not,
# but hw_server and xsdb are unchecked, and a home-built locale costs nothing.
[ -d "$HOME/.locale" ] && export LOCPATH="$HOME/.locale"

# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"
export LD_LIBRARY_PATH="$COMPAT:${LD_LIBRARY_PATH}"

exec "$@"
