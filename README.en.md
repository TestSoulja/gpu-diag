# GPU Diag — diagnose intermittent monitor drop-outs (Windows)

A small PowerShell toolkit for Windows 10/11 that helps find why a monitor
occasionally loses signal (black screen / "no signal") while the GPU is under load.

It installs nothing, makes no network calls, deletes nothing. It produces a report,
records background telemetry, and can apply a few safe, fully reversible power
settings changes.

## Quick start

1. Unpack `GPU-Diag-for-friend.zip` (do not run from inside the archive).
2. Double-click `START-HERE.bat`, accept the UAC prompt.
3. Menu `1` = DO EVERYTHING (report + fixes + background logging). Nothing else to press,
   no reboot required.
4. The Desktop gets `ACTION-RU.txt` (plain-Russian verdict and next steps) and the ZIP to send back.
5. Use the PC normally; logging restarts by itself after every logon.
6. When it happens again: run the tool, menu `4`, send the new ZIP.

Menu: `1` do everything · `2` report only · `3` start logging · `4` stop logging + final ZIP
· `5` apply fixes · `6` undo fixes · `0` exit.

## What it collects

GPU model/driver/mode · driver signature, driver-store leftovers, pending reboot, Windows
Update driver search (read-only) · monitors incl. physical connection type · Device Manager
problem devices · per-process GPU load · `nvidia-smi` telemetry (temp, power, clocks,
throttling, PCIe link) · CPU load/clock/throttling (`Kernel-Processor-Power` id 37) · power
settings (PCIe ASPM, display/sleep timeouts, USB suspend, Fast Startup) · graphics registry
(TDR, HAGS, MPO `OverlayTestMode`) · 30 days of System/Application events (TDR 4101, WHEA,
Kernel-Power 41, BugCheck, PnP) · minidumps and `LiveKernelReports` · WER `LiveKernelEvent`
signatures (141/117) · overclock/overlay software · autostart.

Cross-checks when display errors exist: first crash date vs newest GPU driver package
(driver suspect), HAGS on, MPO enabled, refresh rate above 60 Hz. These are findings only —
the tool never changes HAGS, MPO or the refresh rate itself.

Output ends with a `FINDINGS` section ranked HIGH/MEDIUM/LOW/INFO. The same data is rendered
for the PC owner as `ACTION-RU.txt` on the Desktop (and inside the ZIP): plain Russian,
ranked causes, numbered next steps, what was already fixed automatically, what to send back.

## What the fixes change (all reversible)

PCIe ASPM off · USB selective suspend off · display timeout → never (AC) · Fast Startup off ·
`TdrDelay` 2 → 10 s. Originals are saved to `%LOCALAPPDATA%\GPU-Diag\fix-backup.json`;
menu `6` restores them. No reboot is requested: ASPM/USB/display apply immediately,
Fast Startup at the next shutdown, `TdrDelay` at the next reboot whenever it happens.

## Background logging

Scheduled task `GPU-Diag-Watch` at logon (highest privileges, restarts up to 3 times on
failure). It runs from a stable copy at `%LOCALAPPDATA%\GPU-Diag\engine\GPU-Diag.ps1`, so it
survives reboots, moving or replacing the unpacked folder; the engine version never downgrades.
Files in `%LOCALAPPDATA%\GPU-Diag`: `gpu-watch.csv` (5 s GPU telemetry incl. PCIe gen/width +
active window title), `thermal.csv` (5 s CPU temp/clock), `events.log` (relevant system events
with GPU/CPU/PCIe context at that moment). If the column set changes after an update, the old
`gpu-watch.csv` is renamed to `gpu-watch-<timestamp>.csv` (kept, and packed into the ZIP)
instead of being overwritten.

Note: active window titles end up in the CSV — review before sharing the archive.

## Build the distributable

```powershell
.\build.ps1
```

Produces `dist\GPU-Diag-for-friend.zip` (folder `GPU-Diag` with three files).

## Self-test

```powershell
powershell -ExecutionPolicy Bypass -File .\src\GPU-Diag.ps1 -Mode SelfTest
```

As administrator: applies and reverts every fix, checks task registration, event-log export
and ZIP packaging, prints `RESULT: PASS|FAIL`.

## Requirements

Windows 10/11 with Windows PowerShell 5.1. Admin rights for fixes/logs/scheduler; the report
works without them. `nvidia-smi` block is NVIDIA-only. CPU temperature appears only if the
board exposes an ACPI thermal zone.

## License

MIT — see [LICENSE](LICENSE).
