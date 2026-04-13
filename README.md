# WSL Sleep Manager

**Automatically save and restore your WSL sessions around Windows sleep/wake cycles — without BSOD, without losing your terminal state.**

> Built for Windows 11 S0 Modern Standby machines where WSL 2 / Hyper-V crashes during power state transitions.

---

## The Problem

On Windows 11 systems with **S0 Modern Standby** (connected standby), the Hyper-V hypervisor that powers WSL 2 can crash during sleep/wake transitions — causing BSODs or silently corrupting the WSL environment. The solution is to shut WSL down cleanly *before* the system sleeps, and restore it *after* wake.

The challenge: Windows fires the same power event (`Kernel-Power Event 506`) for both **screen timeout** (monitor off, system still running) and **actual sleep** (user pressed Sleep, lid closed, etc.). A naive script would kill your WSL every time your monitor turns off.

WSL Sleep Manager solves this by reading the **Reason field** from the power event and acting only on genuine sleep events.

---

## Features

- ✅ Distinguishes screen-off from real sleep using `Kernel-Power Event 506` Reason codes
- ✅ Saves all running `tmux` sessions via `tmux-resurrect` before shutdown
- ✅ Restores WSL distros and tmux sessions automatically after wake
- ✅ Zero visible window flash (uses `wscript.exe` VBScript launcher instead of raw `powershell.exe`)
- ✅ Fully logged — every event written to `C:\ProgramData\WSLSleepManager\wsl-sleep-manager.log`
- ✅ 30-second debounce fallback for unknown Reason codes
- ✅ Uninstall option included

---

## Files

| File | Description |
|---|---|
| `WSLSleepManager.bat` | Launcher menu — install, uninstall, view log, tmux setup |
| `Install-WSLSleepManager.ps1` | Main installer — deploys worker scripts + registers Task Scheduler tasks |
| `Install-TmuxResurrect.ps1` | Helper — installs tmux + TPM + tmux-resurrect inside a WSL distro |

---

## Requirements

- Windows 10/11 with WSL 2
- PowerShell 5.1+ (built into Windows)
- Administrator rights for installation
- `git` inside your WSL distro (for tmux-resurrect, optional but recommended)

---

## Installation

### Step 1 — Download all three files into the same folder

```
C:\Tools\WSLSleepManager\
├── WSLSleepManager.bat
├── Install-WSLSleepManager.ps1
└── Install-TmuxResurrect.ps1
```

### Step 2 — Run the launcher as Administrator

Right-click `WSLSleepManager.bat` → **Run as administrator**

```
==========================================
  WSL Sleep Manager
==========================================

  1  Install / Reinstall
  2  Uninstall
  3  View log
  4  Install tmux-resurrect in a distro
  0  Exit
```

Choose **`1`** to install.

### Step 3 — Install tmux-resurrect (recommended)

Choose **`4`** in the menu, then select your WSL distro from the list. The installer will:

1. Check / install `tmux` via `apt`
2. Clone [TPM](https://github.com/tmux-plugins/tpm) into `~/.tmux/plugins/tpm`
3. Add plugin entries to `~/.tmux.conf`
4. Install `tmux-resurrect` via TPM's batch installer

---

## How It Works

### Sleep (Event 506)

When `Kernel-Power Event 506` fires, the pre-sleep script reads the `Reason` field from the Windows event log and decides what to do:

| Reason code | Meaning | Action |
|---|---|---|
| 3 | `SC_MONITORPOWER` — display idle timeout | ❌ WSL untouched |
| 5 | AC/DC Display Burst | ❌ WSL untouched |
| 12 | Connected Standby screen-off (firmware-specific) | ❌ WSL untouched |
| 28 | Display Burst Suppressed | ❌ WSL untouched |
| 31 / 32 / 33 | Input burst (keyboard / mouse / touch) | ❌ WSL untouched |
| 1 | Power Button | ✅ Immediate shutdown |
| 11 | Real sleep transition (confirmed on ASUS S0 hardware) | ✅ Immediate shutdown |
| 15 | Lid close | ✅ Immediate shutdown |
| 20 | Start menu Sleep / API call | ✅ Immediate shutdown |
| −1 | Event log unreadable | ⏳ 30s debounce then shutdown |

When shutdown is confirmed:
1. The list of running distros is saved to a state file
2. `tmux-resurrect` saves all tmux sessions in each distro
3. `wsl --shutdown` terminates the WSL VM cleanly

### Wake (Event 507)

1. If a debounce is still pending (screen came back on within 30s) → cancel, WSL untouched
2. Otherwise → read the saved distro list and restore each one
3. Start a headless `tmux` server and run `tmux-resurrect` restore in the background

---

## After Wake — Using tmux

The tmux environment is restored into a background session. To re-attach:

```bash
# Open a new WSL terminal, then:
tmux attach
# or, if multiple sessions exist:
tmux ls
tmux attach -t main
```

Manual save/restore shortcuts inside tmux:

| Keys | Action |
|---|---|
| `Ctrl+B` then `Ctrl+S` | Save sessions manually |
| `Ctrl+B` then `Ctrl+R` | Restore sessions manually |

> **Note:** `tmux-resurrect` restores window/pane layout, working directories and window names. It does not restore running process output or scrollback history — that is a tmux architecture limitation.

---

## Log File

All events are logged to:

```
C:\ProgramData\WSLSleepManager\wsl-sleep-manager.log
```

View it from the launcher menu (option **`3`**) or directly:

```powershell
Get-Content "$env:ProgramData\WSLSleepManager\wsl-sleep-manager.log" -Tail 30
```

Example log output:

```
[2026-04-13 12:34:44] SLEEP: Event 506 - Reason=12 ('Unknown')
[2026-04-13 12:34:44] SLEEP: Display-only event (Reason=12) - WSL untouched.
[2026-04-13 12:35:09] WAKE: Event 507 received.
[2026-04-13 12:35:09] WAKE: No saved distro list - nothing to restore.
[2026-04-13 12:36:37] SLEEP: Event 506 - Reason=11 ('Unknown')
[2026-04-13 12:36:37] SLEEP: Confirmed sleep event (Reason=11) - shutting down WSL.
[2026-04-13 12:36:37] SLEEP: Distros saved: Ubuntu
[2026-04-13 12:36:37] SLEEP: tmux saved in: Ubuntu
[2026-04-13 12:36:39] SLEEP: wsl --shutdown complete.
[2026-04-13 12:36:40] WAKE: Event 507 received.
[2026-04-13 12:36:42] WAKE: Restoring: Ubuntu
[2026-04-13 12:36:44] WAKE: tmux restored in: Ubuntu
[2026-04-13 12:36:44] WAKE: Done. Restored: Ubuntu
```

---

## Tuning Reason Codes

Reason codes are **firmware-specific** — different machines may use different numeric values for the same event. After your first sleep/wake cycle, check the log to see what Reason code your machine produces on screen-off. If a new screen-off code appears that causes unwanted WSL shutdowns, add it to the `$screenOffReasons` array in the deployed worker script:

```
C:\ProgramData\WSLSleepManager\wsl-pre-sleep.ps1
```

Find this line and add your code:

```powershell
$screenOffReasons = @(3, 5, 12, 28, 31, 32, 33)
```

No reinstall needed — the deployed script is edited directly.

---

## Uninstall

Run `WSLSleepManager.bat` as Administrator and choose **`2`**. This removes:
- Both Task Scheduler tasks (`WSL-PreSleep`, `WSL-PostWake`)
- The entire `C:\ProgramData\WSLSleepManager\` directory

---

## Known Limitations

- **tmux-resurrect does not restore running processes** — only layout, directories and window names. Long-running processes (servers, watchers) must be restarted manually after wake.
- **SSH sessions are not restored** — reconnect manually after wake.
- **S0 Modern Standby only** — on classic S3 sleep systems, Event 506 fires differently and the Reason-based filtering may behave differently. The debounce fallback handles this gracefully.
- **Single user** — the Task Scheduler tasks run under the installing user's session (InteractiveToken). Multi-user setups are not supported.

---

## License

MIT License — see [LICENSE](LICENSE)

```
Copyright (c) 2026 BMSoft1024 (Borsi Miklós)
```

---

## Author

**BMSoft1024** — [github.com/BMSoft1024](https://github.com/BMSoft1024)
