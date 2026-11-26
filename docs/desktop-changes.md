# Remote desktop: every change, and how to undo it

The user's desktop (RTX 3060, Ryzen 5 5600, Windows, at another location), set up
from 2026-11-15 as a second build machine shared by this project (P1) and the
Polytopia engine (P8). This file records everything changed on it, so it can be
returned to normal. Keep it current: add a row whenever something new is changed.

To restore the desktop, undo in **reverse order** (bottom of the table first).
"Done" is what has actually been done; update it as steps are completed.

## Changes on the desktop

| # | Change | Done | How to undo |
|---|---|---|---|
| 2 | Virtualization (SVM) on in the BIOS, if it was off. Optional: "Restore on AC power loss" = On | yes (check whether it was already on) | Harmless to leave. To revert: BIOS, set back to Disabled / Off |
| 3 | Chrome Remote Desktop host installed, unattended, PIN set | yes | Settings → Apps → uninstall **Chrome Remote Desktop Host**; remove the machine at remotedesktop.google.com/access |
| 4 | Power: screen and sleep = Never (plugged in) | yes | Settings → System → Power → set screen/sleep back (Windows default: screen 10 min, sleep 30 min) |
| 7 | WSL turned on (`wsl --install --no-distribution`) | yes | `wsl --uninstall` (admin PowerShell), then reboot |
| 8 | Ubuntu 26.04 installed as distro **`Ubuntu`** in **`D:\WSL\Ubuntu`**; Linux user `rodea` | yes | `wsl --unregister Ubuntu` **deletes everything inside it** (all repos, builds, tools). Then delete the folder `D:\WSL` |
| 9 | `C:\Users\<you>\.wslconfig` created: `networkingMode=mirrored`, `memory=` | yes | Delete the file, then `wsl --shutdown` |
| 10 | NVIDIA driver updated to the current one (580+) | yes | Normally keep it. To roll back: Device Manager → Display adapters → RTX 3060 → Properties → Driver → **Roll Back Driver** |
| 11 | Windows Update active hours set manually (updates possibly paused) | yes | Settings → Windows Update → Advanced options → Active hours = Automatically; **Resume updates** if paused |
| 12 | Tailscale installed, signed in, Run unattended, key expiry disabled | yes | `tailscale logout`; Settings → Apps → uninstall Tailscale; admin console → Machines → the desktop → Remove |
| 13a | Sysinternals Autologon enabled (Windows signs itself in). "Only allow Windows Hello sign-in" turned off if it was on | yes | Run Autologon64.exe → **Disable**. Turn "Only allow Windows Hello sign-in" back on if it was on before |
| 13b | Scheduled task **"WSL keep-alive"** (runs `wsl.exe -d Ubuntu --exec sleep infinity` at sign-in) | yes | `Unregister-ScheduledTask -TaskName "WSL keep-alive" -Confirm:$false` (admin PowerShell) |
| 14–17 | Inside Ubuntu: systemd, apt packages, Nix, SSH server (key-only) | yes (2026-11-20) | Gone with `wsl --unregister Ubuntu` (row 8); nothing outside the distro |
| 18 | *Only if SSH timed out:* Hyper-V firewall rule **WSL-SSH** (inbound TCP 22) | **not needed**: SSH over Tailscale worked first try (2026-11-20) | `Remove-NetFirewallHyperVRule -Name WSL-SSH` (admin PowerShell) |

**Reboot test passed 2026-11-20:** Windows booted 12:47:14, WSL up 12:47:42 (Autologon →
keep-alive task), SSH over Tailscale reachable without anyone signing in.

Over SSH, Windows programs are not on the PATH: call them by full path, e.g.
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`, and
`/usr/lib/wsl/lib/nvidia-smi`.

Step numbers match the setup list given in the P1 session of 2026-11-15
(Part A on site, Part B by the user via Chrome Remote Desktop, Part C by Claude
Code over SSH). Part C only touches files inside the Ubuntu distro, so row 8
undoes all of it.

**Part C, P1 (inside the distro, home folder, no sudo), from 2026-11-20:** `gh` in
`~/.local/bin` (signed in as RodeanAzari, `~/.config/gh`); repo cloned to
`~/riscv-rv32i-tmr-core` (branch `array-cdc`); `~/cocotb-env`; OSS CAD Suite in
`~/.local/opt`; Verilator 5.050 (`~/.local/src/verilator`, installed to `~/.local`);
LibreLane in `~/librelane` with Nix's store and the PDK in `~/.ciel`;
`~/riscv-toolchain` copied from the laptop; a second worktree `~/p1-llm`
(2026-11-26, `git worktree add`; remove with `git worktree remove ~/p1-llm`);
PATH lines appended to `~/.bashrc`;
install script and logs `~/p1-tools.sh`, `~/p1-tools.log`, `~/setup-logs/`.
To sign the desktop out of GitHub: `gh auth logout`, and revoke it at
github.com → Settings → Applications.

## Changes on the laptop (for the same setup)

| Change | How to undo |
|---|---|
| Tailscale installed on Windows, same account | `tailscale logout`, uninstall |
| SSH key `~/.ssh/id_ed25519` (WSL, no passphrase, comment `rodea-laptop-wsl`), created 2026-11-20; its public half goes in the desktop's `authorized_keys` | Delete both key files; remove the line from the desktop's `~/.ssh/authorized_keys` (or it goes with row 8) |
| `Host desktop` entry in `~/.ssh/config` (WSL), HostName `rodeandesktop`, added 2026-11-20 | Delete those lines; also the `rodeandesktop` line in `~/.ssh/known_hosts` |

## Full return to normal, short version

1. `Unregister-ScheduledTask -TaskName "WSL keep-alive" -Confirm:$false`
2. Autologon64.exe → Disable
3. `Remove-NetFirewallHyperVRule -Name WSL-SSH` (if it was created)
4. Tailscale: log out, uninstall, remove from the admin console
5. `wsl --unregister Ubuntu`, delete `D:\WSL` and `.wslconfig`, then `wsl --uninstall`, reboot
6. Power and Windows Update settings back to default
7. Chrome Remote Desktop last (it's the way in), unless someone is at the desktop
