# Vivado Setup (WSL2)

Reference for installing Vivado and wiring it into this repo's build flow.
Written 2026-09-03 before the install; corrected 2026-09-04 against what
Vivado **2026.1** actually did on this machine. Where the two differ, the
2026.1 behaviour is marked.

Target board: **Arty A7** (Artix-7, XC7A35T or XC7A100T).

---

## 1. Download

Requires a free AMD account at [amd.com](https://amd.com).

Get the **AMD Unified Installer for FPGAs & Adaptive SoCs**, specifically the
**Linux Self Extracting Web Installer** (`.bin`). Not the Windows installer —
Vivado should run natively in WSL so `make synth` can call it directly without
`/mnt/c` path translation.

It downloads on the Windows side, so move it over:

```bash
cp /mnt/c/Users/<you>/Downloads/FPGAs_AdaptiveSoCs_Unified_*.bin ~/
chmod +x ~/FPGAs_AdaptiveSoCs_Unified_*.bin
~/FPGAs_AdaptiveSoCs_Unified_*.bin
```

The GUI installer displays fine under WSLg (`/mnt/wslg` is mounted).

### Version: must be 2025.2 or earlier

**This is not a preference. On Linux it is the difference between free and
$1,200/year.**

AMD restructured licensing in **2026.1**: the free tier (renamed "Vivado
BASIC") became **Windows-only**, and now requires annual renewal. Linux users
on 2026.1 must buy a subscription (~$1,200–$1,800/yr) or a perpetual license
($10,000+). There is no free Linux path on 2026.1 — `vlm` offers only a 60-day
trial or a paid/certificate-based license.

Every release **up to and including 2025.2** keeps Vivado ML **Standard** free
on Linux with **no license file at all**. That is what this project uses.

Get 2025.2 from the download archive, not the current-release page:
[Vivado design tools archive](https://www.xilinx.com/support/download.html/content/xilinx/en/downloadNav/vivado-design-tools/archive.html)

Also confirm **Artix-7 appears in the device list** during install — AMD has
been narrowing 7-series support over time. 2024.2 and 2025.1 are equally valid
fallbacks if 2025.2 gives trouble; both are well documented with the Arty A7.

---

## 2. Install choices

| Prompt | Choose |
|---|---|
| Product | **Vivado** |
| Edition | **Vivado ML Standard** — free, no license file, covers Artix-7. Enterprise is the paid tier and will refuse to launch without a license; see §5 |
| Devices | Uncheck everything except **Artix-7** |
| Install path | anywhere under `$HOME` — see note below |

**Why a home-directory install and not `/tools/Xilinx`:** it needs no root.
`sudo` cannot prompt for a password through the Claude Code interface, so
anything requiring root has to be done in a separate terminal. Avoiding it
entirely is simpler.

**On the path field: type the absolute path, not `~`.** The installer does not
expand tilde and rejects `~/Xilinx` with "invalid character". Enter
`/home/rodea/Xilinx`. Then check the panel's final-destination summary — if it
shows the directory nested inside itself, back the field off to `/home/rodea`.

Any writable directory works; `~/xilinx` lowercase is equally fine. The
`vivado-env` function in §3 globs `[Xx]ilinx`, so either spelling resolves.
Note `~/.Xilinx` — the registry and installer-log directory — is separate,
always capitalized, and created regardless of where the tools land.

**Size:** ~100 GB for everything, ~30–50 GB with only Artix-7 selected.
Check headroom with `df -h /home` (was 944 GB free at time of writing).

### What actually got installed (2026-09-04)

63 GB at `~/Xilinx`. Artix-7 landed correctly — part data for both Arty A7
variants (`xc7a35t_csg324`, `xc7a100t_csg324`) is present under
`~/Xilinx/2026.1/Vivado/data/parts/xilinx/artix7/`, and the installer log
confirms `7 Series → Artix-7 FPGAs` was selected.

Three things did not go to plan:

- **Wrong version.** 2026.1 cannot run free on Linux at all (see §1). This is
  the fatal one — the install was abandoned and replaced with 2025.2.
- **Enterprise, not Standard.** The installer log records
  `selectedPackage=VivadoMLEnterpriseEdition`. Moot once the version changed,
  but pick **Standard** on the retry.
- **Vitis got installed alongside Vivado**, which accounts for a chunk of the
  63 GB. Harmless, just not needed for this project.

The installer also warns that Debian/WSL is not a supported OS for 2026.1
(it lists RHEL, Rocky, SUSE, Amazon Linux, Ubuntu, AlmaLinux). It installs and
runs anyway; the locale crash in §3 is the one concrete symptom seen so far.

---

## 3. PATH — do NOT source settings64.sh globally

**The path layout differs by release.** 2026.1 uses
`~/Xilinx/<version>/Vivado/`; releases before it use
`~/Xilinx/Vivado/<version>/`. Do not hardcode either — the `vivado-env`
function below detects whichever is present.

The obvious move is appending this to `~/.bashrc`:

```bash
source ~/Xilinx/Vivado/2025.2/settings64.sh   # <-- don't
```

**Why not:** `settings64.sh` prepends Vivado's bundled libraries to
`LD_LIBRARY_PATH`. Those include older `libstdc++`, `libssl`, and `libcurl`
builds that shadow the system versions. The usual symptom is `git`, `curl`, or
Python breaking with confusing library errors in every new shell — and the
cause is not obvious once you've forgotten you added the line.

### Do this instead

Add to `~/.bashrc`:

```bash
# Layout differs by release: ~/Xilinx/<ver>/Vivado/ in 2026.1+,
# ~/Xilinx/Vivado/<ver>/ before that. Pick the newest of either.
vivado-env() {
    export LOCPATH="$HOME/.locale"
    local s
    s=$(ls -d "$HOME"/[Xx]ilinx/*/Vivado/settings64.sh \
              "$HOME"/[Xx]ilinx/Vivado/*/settings64.sh 2>/dev/null | sort -V | tail -1)
    if [ -z "$s" ]; then
        echo "vivado-env: no Vivado install found under ~/Xilinx" >&2
        return 1
    fi
    source "$s"
    # Ubuntu 26.04 has no libncurses5/libtinfo5; Vivado's Tcl extensions need
    # them. Compat symlinks onto ncurses 6. Must come after settings64.sh,
    # which sets LD_LIBRARY_PATH itself.
    export LD_LIBRARY_PATH="$HOME/.local/lib/vivado-compat:$LD_LIBRARY_PATH"
}
```

This is live in `~/.bashrc`.

Run `vivado-env` only in shells that need Vivado. Everything else stays clean.

### The locale crash (2026.1)

`bin/rdiArgs.sh` unconditionally forces `LC_ALL=en_US.UTF-8`. Debian generates
only `C`, `C.utf8`, and `POSIX`, so every Vivado invocation died with:

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  locale::facet::_S_create_c_locale name not valid
```

The message Vivado prints tells you to run `sudo locale-gen`, which needs root
— unavailable here (see the `sudo` note in PROGRESS.md). Generate the locale
into the home directory instead and point glibc at it with `LOCPATH`:

```bash
mkdir -p ~/.locale
localedef -i en_US -f UTF-8 ~/.locale/en_US.UTF-8
export LOCPATH="$HOME/.locale"
```

Done once, already in place. `locale -a` still will not list it — that is
cosmetic, and Vivado's own check still prints its WARNING — but `setlocale()`
resolves and the crash goes away. Keep `LOCPATH` scoped to `vivado-env` rather
than exporting it globally.

**2025.2 does not have this problem** — it does not force the locale, and runs
silently. `LOCPATH` is retained in `vivado-env` anyway: it costs nothing, and
the other Xilinx binaries (`vlm`, `hw_server`, `xsdb`) have not been checked.

### The missing libncurses5 (Ubuntu 26.04)

This one actually blocks the tools. Vivado 2025.2's Tcl extensions link against
ncurses 5, which Ubuntu 26.04 does not package at all — the system has only
`libncursesw.so.6` and `libtinfo.so.6`, and not even a non-wide
`libncurses.so.6`. The failure:

```
application-specific initialization failed: couldn't load file
"libxv_commontasks.so": libncurses.so.5: cannot open shared object file
```

Worse, this does not always surface as an error. The first `-mode batch` run
**hung** rather than failing — Vivado printed nothing, sat at 0% CPU for over
ten minutes, and had to be killed. It appears to fall through to an interactive
Tcl prompt waiting on stdin after init fails. If a batch run hangs with no
output, suspect this before suspecting a slow part-database build.

Fix with compat symlinks, no root needed:

```bash
mkdir -p ~/.local/lib/vivado-compat
cd ~/.local/lib/vivado-compat
ln -sf /lib/x86_64-linux-gnu/libncursesw.so.6 libncurses.so.5
ln -sf /lib/x86_64-linux-gnu/libncursesw.so.6 libncursesw.so.5
ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6    libtinfo.so.5
```

`vivado-env` prepends that directory to `LD_LIBRARY_PATH` after sourcing
`settings64.sh`. Already in place. The ncurses 5→6 ABI difference is not a
problem for how Vivado uses it.

Note that `settings64.sh` sets `PATH`, `XILINX_VIVADO`, and the library
variables together — do not try to add `bin/` to `PATH` manually instead, it
will not work correctly on its own.

The `syn/` Tcl scripts should source `settings64.sh` themselves, so
`make synth` works without Vivado being in the interactive environment at all.

---

## 4. Verify the install

```bash
vivado-env
vivado -version
which vivado          # under ~/Xilinx, exact layout depends on release
echo $XILINX_VIVADO
```

Confirm the device is actually present:

```bash
vivado -mode batch -nojournal -nolog -tcl "puts [get_parts xc7a*]; exit"
```

An empty result means Artix-7 was not installed — rerun the installer and add it.

On a correct Standard install this just works. If it dies at launch with a
license error, that is §5 — the failure happens before `get_parts` ever runs,
so it looks like a device problem but is not. To check devices without
launching Vivado, look for the part data on disk:

```bash
ls "$XILINX_VIVADO"/data/parts/xilinx/artix7/public/bsdl/ | grep -E '7a(35|100)t'
```

### Verified 2026-09-05, Vivado 2025.2

`vivado -version` → `v2025.2 (64-bit)`, SW Build 6299465, **no license error**
and no locale warning. Part queries returned 30 `xc7a35t*` and 24 `xc7a100t*`
parts. Both Arty A7 devices resolve, with resources matching the datasheets:

| Part | Board | LUTs | FFs | BRAM | DSP |
|---|---|---|---|---|---|
| `xc7a35ticsg324-1L` | Arty A7-35T | 20,800 | 41,600 | 50 | 90 |
| `xc7a100tcsg324-1` | Arty A7-100T | 63,400 | 126,800 | 135 | 240 |

Those LUT/FF/BRAM/DSP totals are the denominators for the utilization
percentages the README has to report (CLAUDE.md §10), and the baseline the TMR
area-overhead number in Phase E is measured against.

---

## 5. Licensing

**Vivado ML Standard ≤ 2025.2 on Linux needs no license file.** If the tools
run, licensing is done. There is nothing to obtain, install, or renew.

If you see this:

```
ERROR: Vivado Design Suite cannot be launched because a valid license was not
found. Visit the Vivado Licensing page to choose and generate the right license.
```

the cause is one of two things, and neither is fixed by hunting for a license:

1. **You installed 2026.1 or later.** No free Linux tier exists there (§1).
   `vlm` will show only "60-day trial" and "Get Full or Certificate Based
   License" — the free option is absent, not hidden. Downgrade.
2. **You installed Enterprise instead of Standard** on a version where
   Standard would have been free. Re-run
   `~/Xilinx/.xinstall/<ver>/xsetup` and change the edition.

Do **not** start the 60-day trial as a workaround. This project runs 10–14
weeks; the trial expires mid-Phase-D and leaves the synthesis flow dead at the
worst moment.

### Removing a bad install

The GUI uninstaller is `~/Xilinx/.xinstall/<ver>/xuninstall`, but the install is
self-contained, so deleting it directly is equivalent and needs no clicking.
Close any running `vlm` / Vivado / Information Center processes first, then:

```bash
rm -rf ~/[Xx]ilinx                  # the tools; NOT ~/.Xilinx
rm -f ~/.Xilinx/registry/*.xml      # stale entries confuse the next installer
rm -rf /tmp/TMP_LD_LIB_PATH*
```

Keep `~/.Xilinx/xinstall/*.log` — the installer log is the only record of which
edition and devices were actually selected, and is how the Enterprise mistake
in §2 was diagnosed.

---

## 6. JTAG programming from WSL2

**WSL2 cannot see USB devices by default**, so no programmer running inside
WSL will find the Arty A7 out of the box. That includes Vivado's Hardware
Manager and `openFPGALoader`. `openFPGALoader` replaces Hardware Manager; it
does not get around the USB problem. Two options:

| Approach | Notes |
|---|---|
| **`usbipd-win` + `openFPGALoader` in WSL** | `usbipd-win` (Windows side) attaches the Digilent USB device into WSL; `openFPGALoader -b arty_a7_100t` (plain `arty` is the 35T) programs the bitstream from there. Scripts cleanly into `make prog`. Needs `usbipd attach` again after every reboot or replug. |
| **Program from Windows** | Build the `.bit` in WSL, load it with Hardware Manager or `openFPGALoader` on Windows via `\\wsl$\...`. No USB passthrough, but `make prog` cannot do the programming itself. |

The board's USB-UART has the same limit: it is a Windows COM port, reachable
from WSL only through `usbipd-win`. **Chosen
(2026-10-16/17): both, picked per session.** Set up first: program from
Windows with Vivado Lab Edition 2025.2 (install with "Install Cable Drivers"
ticked), and read the UART in a Windows terminal (PuTTY or Tera Term) on the
board's COM port. Set up after first light: `usbipd-win` + `openFPGALoader`
in WSL, the faster route for everyday runs. The USB device is on one side at
a time: `usbipd attach` hides it from Windows (Hardware Manager and the COM
port) until `usbipd detach`.

### Setting up the WSL route (usbipd-win + openFPGALoader)

`openFPGALoader` comes with OSS CAD Suite (v1.1.1 in the 2026-10-07
bundle), and the WSL kernel has the USB/IP and FTDI serial drivers. The
Arty is an FTDI FT2232H, `0403:6010`: interface A is JTAG, B the UART.

Once, on Windows, in an **administrator** PowerShell:

    winget install --interactive --exact dorssel.usbipd-win
    usbipd list                      # find the Arty's BUSID (0403:6010)
    usbipd bind --busid <BUSID>      # share it; survives reboots

Once, in WSL (root, so in a terminal of your own -- Claude Code cannot
answer sudo's prompt):

    sudo cp scripts/99-arty-a7.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger

Each session (after every replug or reboot), on Windows, no admin needed:

    usbipd attach --wsl --busid <BUSID>    # board leaves Windows, joins WSL
    usbipd detach --busid <BUSID>          # and back again

While attached to WSL, `make prog` programs the board with
`openFPGALoader -b arty_a7_100t`, and the UART is `/dev/ttyUSB1` (`screen
/dev/ttyUSB1 115200`). While detached, `make prog` prints the Hardware
Manager steps instead.

Synthesis, implementation, and timing closure all work regardless — only the
final bitstream download needs the USB path.

---

## 7. After install — repo work to do

Done (2026-09-05):

- [x] `scripts/setup-vivado-env.sh` — locates and sources `settings64.sh` in a
      subshell, applies the ncurses and locale fixups from §3
- [x] `syn/synth_ooc.tcl` — out-of-context synth → opt → place → route, emitting
      utilization, timing and a derived-Fmax summary into `docs/reports/`
- [x] `make synth` target in the root `Makefile`

Still outstanding, both Phase D:

- [ ] `constr/arty_a7.xdc` — pin and timing constraints for a board-level top
- [ ] `make impl` (board-level P&R → bitstream) and `make prog`, the latter
      blocked on USB passthrough (§6)

Synthesis is **deliberately not in hosted CI** — Vivado is too large for a
GitHub-hosted runner. See CLAUDE.md §4: the substitute is that reports are
committed to `docs/reports/` alongside the RTL that produced them. A self-hosted
runner is the upgrade path if that stops being enough.

Per CLAUDE.md §10's measurement discipline, timing closure reports get
**committed**, and the README carries **measured** Fmax and LUT/FF/BRAM/DSP
numbers — not adjectives — each one transcribed from a generated report rather
than typed from memory.

---

## Current toolchain state (2026-09-04)

| Tool | Status |
|---|---|
| Verilator 5.050 | `~/.local/bin/verilator`, built from source |
| cocotb 2.0.1 | `~/cocotb-env` |
| riscv32-unknown-elf-gcc 16.1.0 | `~/riscv-toolchain/bin` |
| spike | `~/riscv-toolchain/bin/spike` |
| Vivado 2026.1 | installed, then **removed** 2026-09-04 — no free Linux tier (§1) |
| Vivado 2025.2 | **installed and verified** at `~/Xilinx/2025.2/Vivado`, ML Standard, 54 GB. No license file needed |
| SymbiYosys / yosys (Phase B) | **not installed** |
