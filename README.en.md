# GPU Diag — diagnose intermittent monitor drop-outs (Windows)

A small PowerShell toolkit for Windows 10/11 that helps find why a monitor
occasionally loses signal (black screen / "no signal") while the GPU is under load.

It installs nothing, makes no network calls, deletes nothing. It produces a report,
records background telemetry, and can apply a few safe, fully reversible power
settings changes.

## Quick start

1. Unpack `GPU-Diag-for-friend.zip` (do not run from inside the archive).
2. Double-click `START-HERE.bat`, accept the UAC prompt.
3. Menu `1` = DO EVERYTHING (report + fixes + background logging), then reboot.
4. Use the PC normally.
5. When it happens again: run the tool, menu `4`, send the ZIP from the Desktop.

Menu: `1` do everything · `2` report only · `3` start logging · `4` stop logging + final ZIP
· `5` apply fixes · `6` undo fixes · `0` exit.

## What it collects

GPU model/driver/mode · driver signature, driver-store leftovers, pending reboot, Windows
Update driver search (read-only) · monitors incl. physical connection type · Device Manager
problem devices · per-process GPU load · `nvidia-smi` telemetry (temp, power, clocks,
throttling, PCIe link) · CPU load/clock/throttling (`Kernel-Processor-Power` id 37) · power
settings (PCIe ASPM, display/sleep timeouts, USB suspend, Fast Startup) · graphics registry
(TDR, HAGS) · 30 days of System/Application events (TDR 4101, WHEA, Kernel-Power 41, BugCheck,
PnP) · minidumps and `LiveKernelReports` · WER `LiveKernelEvent` signatures (141/117) ·
overclock/overlay software · autostart.

Output ends with a `FINDINGS` section ranked HIGH/MEDIUM/LOW/INFO.

## What the fixes change (all reversible)

PCIe ASPM off · USB selective suspend off · display timeout → never (AC) · Fast Startup off ·
`TdrDelay` 2 → 10 s. Originals are saved to `%LOCALAPPDATA%\GPU-Diag\fix-backup.json`;
menu `6` restores them. Reboot needed for TDR/Fast Startup.

## Background logging

Scheduled task `GPU-Diag-Watch` at logon (highest privileges). Files in
`%LOCALAPPDATA%\GPU-Diag`: `gpu-watch.csv` (5 s GPU telemetry + active window title),
`thermal.csv` (5 s CPU temp/clock), `events.log` (relevant system events with GPU/CPU
context at that moment).

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
