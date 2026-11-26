# GPU Diag — diagnose intermittent monitor drop-outs (Windows)

**Русская документация:** [README.md](README.md)

A small PowerShell toolkit for Windows 10/11 that helps find why a monitor
occasionally loses signal (black screen / "no signal") while the GPU is under load.

It installs no services or drivers. It registers the `GPU-Diag-Watch` scheduled task and
copies its engine into the user profile (`%LOCALAPPDATA%\GPU-Diag\engine`). It makes no
network calls of its own: the only outbound request is the driver update search through the
Windows Update service, and Windows itself performs it. It does not delete logs, reports or
dumps. It produces a report, records background telemetry, and can apply a few safe, fully
reversible power settings changes.

## Quick start

1. Unpack `GPU-Diag.zip` (do not run from inside the archive).
2. Double-click `START-HERE.bat`, accept the UAC prompt.
3. Menu `1` = DO EVERYTHING (report + fixes + background logging). Nothing else to press,
   no reboot required.
4. The Desktop gets `ACTION-RU.txt` (plain-Russian verdict and next steps) and the ZIP
   with your report: full details, event log and telemetry.
5. Use the PC normally; logging restarts by itself after every logon.
6. When it happens again: run the tool, menu `4` — the new ZIP is the updated report.

Menu: `1` do everything · `2` report only · `3` start logging · `4` stop logging + case ZIP
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
ranked causes, numbered next steps, what was already fixed automatically, and what to do
with the ZIP. The same file lists every ZIP entry and what it is for.

## What the fixes change (all reversible)

PCIe ASPM off · USB selective suspend off · display timeout → never (AC) · Fast Startup off ·
`TdrDelay` 2 → 10 s. Originals are saved to `%LOCALAPPDATA%\GPU-Diag\fix-backup.json`;
menu `6` restores them. No reboot is requested: ASPM/USB/display apply immediately,
Fast Startup at the next shutdown, `TdrDelay` at the next reboot whenever it happens.

## Background logging

Scheduled task `GPU-Diag-Watch` at logon (highest privileges, restarts up to 3 times on
failure). It runs from a stable copy at `%LOCALAPPDATA%\GPU-Diag\engine\GPU-Diag.ps1`, so it
survives reboots, moving or replacing the unpacked folder; the engine version never downgrades.
Files in `%LOCALAPPDATA%\GPU-Diag`: `gpu-watch.csv` (GPU telemetry about every 5 s incl. PCIe
gen/width + active window title), `thermal.csv` (CPU temp/clock about every 5 s), `events.log`
(relevant system events with GPU/CPU/PCIe context at that moment), `watch-errors.log`
(logger errors including a failed rotation).

Logs rotate by themselves. When `gpu-watch.csv` or `thermal.csv` reaches 10 MB it is renamed
to `gpu-watch-<date>-<time>.csv` (or `thermal-...`) and logging continues in a fresh current
file. The whole log folder is capped at 100 MB: after a rotation the oldest segments are
deleted until the total `.csv` + `.log` size is at or below the cap. The current files,
`state.json`, `stop.flag`, `fix-backup.json`, `events.log` and `watch-errors.log` are never
deleted. The cap is held by deleting old segments; `events.log` and `watch-errors.log`
themselves are never deleted, so in an extreme case the folder can exceed 100 MB. Trimming
runs only when a rotation in that pass succeeded, so a failed rotation leaves old segments
in place and the folder can exceed 100 MB. A failed rotation is written to `watch-errors.log`
as `rotation failed` at most once per 10 minutes per file; a later success adds one
`rotation ok` line. The 27.11.2026 measurement gave about 3.8 MB per day (4 369 records in
6.5 h, one record every 5.41 s), so 100 MB is roughly 25–26 days of history.

The engine folder is write-restricted to Administrators at install time (the user keeps
read/execute and can delete it), because the task runs that script elevated. This stops
casual or accidental replacement, not a determined local attacker: the profile owner can
always restore their own permissions.

## Privacy

The script makes no network requests. The only exception is the driver update search through
the local Windows Update service (Windows itself performs the request).

Note: active window titles end up in `gpu-watch.csv` — there may be site and chat names.
Review the file before sharing the archive.

Note about dumps: the ZIP copies dumps from `C:\Windows\Minidump` (`minidumps\`) — they are
memory fragments. Review them before sharing the archive with third parties, just like
`gpu-watch.csv`. `live-kernel-reports.txt` contains only a list of `LiveKernelReports` files
(name, size, path); the dumps themselves are not copied from there.

## Uninstall

Nothing is installed as a service or driver. To remove everything:

1. `START-HERE.bat` → menu `4` — stops logging and removes the `GPU-Diag-Watch` task.
2. Menu `6` — restores every changed setting to its original value.
3. Delete `%LOCALAPPDATA%\GPU-Diag` (logs, fix backup, engine copy).
4. Delete the unpacked folder with `START-HERE.bat`.

If the folder is already gone but the task remains, run as administrator:
`schtasks /Delete /TN GPU-Diag-Watch /F`. No reboot needed.

## Build the distributable

```powershell
.\build.ps1
```

Produces `dist\GPU-Diag.zip` (folder `GPU-Diag` with three files).

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
