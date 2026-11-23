#Requires -Version 5.1
<#
  GPU / DISPLAY PROBLEM DIAGNOSTICS
  ------------------------------------------------------------------
  For a PC whose monitor turns off / loses signal now and then while the
  GPU appears to be at peak load.

  What it does:
    * Report  : read-only analysis. GPU, driver, monitors + connection type,
                power settings, graphics registry, event logs (TDR / WHEA /
                Kernel-Power 41 / BugCheck), live kernel dumps, minidumps,
                current GPU load per process, nvidia-smi live values,
                autostart + overclock software. Produces a ZIP to send back.
    * Watch   : lightweight background logger (runs at every logon via a
                scheduled task) that records GPU telemetry every 5 s and
                every relevant system event. Catches the moment of the drop.
    * Fix     : a few safe, reversible changes (PCIe power saving, USB
                selective suspend, monitor timeout, Fast Startup, TDR delay).
                Full backup is written first; Revert puts everything back.

  Nothing is uploaded anywhere. All output stays in local files.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Report','Fix','Revert','Watch','InstallWatch','UninstallWatch','Finish','SelfTest')]
    [string]$Mode = 'Menu',
    [string]$OutRoot = '',
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$script:Version        = '1.2'
$TaskName              = 'GPU-Diag-Watch'
$LogDir                = Join-Path $env:LOCALAPPDATA 'GPU-Diag'
if (-not $OutRoot) { $OutRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'GPU-DIAG' }

# power setting GUIDs (used instead of localized aliases)
$PC = @{
    PcieSub = '501a4d13-42af-4429-9fd1-a8218c268e20'
    PcieAsm = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
    VideoSub = '7516b95f-f776-4464-8c53-06167f40cc99'
    VideoIdle = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    UsbSub  = '2a737441-1930-4402-8d77-b2bebba308a3'
    UsbSus  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    SleepSub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    SleepIdle = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
}

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Say { param([string]$Text) Write-Host $Text }

# ---- elevation ------------------------------------------------------------
$isAdmin = Test-Admin
if (-not $isAdmin -and $Mode -ne 'Watch' -and -not $env:GPU_DIAG_NOELEVATE) {
    $q = '"' + $PSCommandPath + '"'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $q, '-Mode', $Mode)
    if ($OutRoot) { $argList += @('-OutRoot', ('"' + $OutRoot + '"')) }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        exit
    } catch {
        Write-Host ' [!] Elevation was cancelled - running without admin rights (some parts will be missing).' -ForegroundColor Yellow
        $env:GPU_DIAG_NOELEVATE = '1'
    }
}

# ----------------------------------------------------------------------------
# report buffer
# ----------------------------------------------------------------------------
$script:Rep      = New-Object System.Collections.Generic.List[string]
$script:Findings = New-Object System.Collections.Generic.List[string]

function W      { param([string]$Text = '') $script:Rep.Add($Text) }
function Hdr    { param([string]$Text) W ''; W ('-' * 78); W ('  ' + $Text); W ('-' * 78) }
function KV {
    param([string]$Key, $Value)
    if ($null -eq $Value -or "$Value" -eq '') { $Value = '(n/a)' }
    W ('  {0,-32}: {1}' -f $Key, $Value)
}
function Finding {
    param([string]$Level, [string]$Text)
    $script:Findings.Add(('[{0}] {1}' -f $Level, $Text))
}
function Show {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '(n/a)' }
    return "$Value"
}

# ----------------------------------------------------------------------------
# hardware / os / gpu queries
# ----------------------------------------------------------------------------
function Get-Gpus {
    $list = @()
    try { $raw = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop } catch { return $list }
    foreach ($g in $raw) {
        $ven = ''
        if ($g.PNPDeviceID -and ($g.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4})')) { $ven = $Matches[1].ToUpper() }
        $vendor = switch ($ven) { '10DE' { 'NVIDIA' } '1002' { 'AMD' } '8086' { 'Intel' } default { $ven } }
        $res = ''
        if ($g.CurrentHorizontalResolution) { $res = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution) @ $($g.CurrentRefreshRate) Hz" }
        $list += [pscustomobject]@{
            Name       = $g.Name
            Vendor     = $vendor
            DriverVer  = $g.DriverVersion
            DriverDate = $g.DriverDate
            Resolution = $res
            Status     = $g.Status
            Pnp        = $g.PNPDeviceID
        }
    }
    return $list
}

function Decode-MonName {
    param($Arr)
    if (-not $Arr) { return '' }
    $s = -join ($Arr | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
    return $s.Trim()
}

function Convert-OutputTech {
    param($Value)
    if ($null -eq $Value) { return '' }
    try { $n = [uint32]$Value } catch { return "$Value" }
    if ($n -eq 2147483648) { return 'Internal panel' }
    $map = @{
        0 = 'VGA'; 1 = 'S-Video'; 2 = 'Composite'; 3 = 'Component'; 4 = 'DVI'
        5 = 'HDMI'; 6 = 'LVDS (internal)'; 8 = 'D-Terminal'; 9 = 'SDI'
        10 = 'DisplayPort (external)'; 11 = 'DisplayPort (internal)'; 12 = 'UDI external'
        13 = 'UDI internal'; 14 = 'SDTV dongle'; 15 = 'Miracast/WiDi'; 16 = 'Indirect wired'
    }
    if ($map.ContainsKey([int]$n)) { return $map[[int]$n] }
    return "Other ($n)"
}

function Get-Monitors {
    $res = @()
    try { $mons = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop } catch { return $res }
    $conn = @()
    try { $conn = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop } catch { }
    foreach ($m in $mons) {
        $c = $null
        if ($conn) { $c = $conn | Where-Object { $_.InstanceName -eq $m.InstanceName } | Select-Object -First 1 }
        $tech = ''
        if ($c) { $tech = Convert-OutputTech $c.VideoOutputTechnology }
        $res += [pscustomobject]@{
            Name   = (Decode-MonName $m.UserFriendlyName)
            Maker  = (Decode-MonName $m.ManufacturerName)
            Serial = (Decode-MonName $m.SerialNumberID)
            Year   = $m.YearOfManufacture
            Active = $m.Active
            Tech   = $tech
            Id     = $m.InstanceName
        }
    }
    return $res
}

function Get-NvSmiPath {
    foreach ($p in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-NvRaw {
    param([string]$Smi, [string]$Query)
    if (-not $Smi) { return $null }
    try {
        $out = & $Smi '-i' '0' ('--query-gpu=' + $Query) '--format=csv,noheader,nounits' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return ((($out | Select-Object -First 1) -join ' ') -split '\s*,\s*')
    } catch { return $null }
}

function Get-NvSample {
    param([string]$Smi)
    if (-not $Smi) { return $null }
    $q = 'name,driver_version,temperature.gpu,utilization.gpu,utilization.memory,memory.used,power.draw,power.limit,clocks.sm,clocks.mem,fan.speed,pstate,clocks_throttle_reasons.active'
    $v = Get-NvRaw -Smi $Smi -Query $q
    if (-not $v -or $v.Count -lt 13) { return $null }
    return [pscustomobject]@{
        Name       = $v[0];  Driver     = $v[1];  Temp    = $v[2]
        UtilGpu    = $v[3];  UtilMem    = $v[4];  MemUsed = $v[5]
        Power      = $v[6];  PowerLimit = $v[7];  ClockSm = $v[8]
        ClockMem   = $v[9];  Fan        = $v[10]; PState  = $v[11]
        Throttle   = $v[12]
    }
}

function Convert-ThrottleBits {
    param([string]$Hex)
    if (-not $Hex) { return '' }
    $clean = $Hex.Trim()
    try { $v = [Convert]::ToInt64($clean, 16) } catch { return $clean }
    if ($v -eq 0) { return 'none' }
    $bits = @(
        @(1, 'GpuIdle'), @(2, 'AppClocks'), @(4, 'SwPowerCap'), @(8, 'HwSlowdown'),
        @(16, 'SyncBoost'), @(32, 'SwThermal'), @(64, 'HwThermal'), @(128, 'HwPowerBrake'), @(256, 'DisplayClock')
    )
    $names = @()
    foreach ($b in $bits) { if (($v -band $b[0]) -ne 0) { $names += $b[1] } }
    return ($names -join '+')
}

function Get-GpuLoad {
    $out = [pscustomobject]@{ Total = 0.0; Top = @(); Error = '' }
    try {
        $samples = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop
    } catch {
        $out.Error = $_.Exception.Message
        return $out
    }
    $perSample = @()
    foreach ($s in $samples) {
        $h = @{}
        foreach ($c in $s.CounterSamples) {
            if ($c.InstanceName -notmatch 'pid_(\d+)_') { continue }
            $procId = [int]$Matches[1]
            $val = [double]$c.CookedValue
            if ($val -le 0) { continue }
            if (-not $h.ContainsKey($procId)) { $h[$procId] = 0.0 }
            $h[$procId] = $h[$procId] + $val
        }
        $perSample += , $h
    }
    $maxPerPid = @{}
    $totalMax = 0.0
    foreach ($h in $perSample) {
        $sum = 0.0
        foreach ($k in $h.Keys) {
            $sum += $h[$k]
            if (-not $maxPerPid.ContainsKey($k) -or $h[$k] -gt $maxPerPid[$k]) { $maxPerPid[$k] = $h[$k] }
        }
        if ($sum -gt $totalMax) { $totalMax = $sum }
    }
    $out.Total = [math]::Round($totalMax, 1)
    $top = @()
    $pids = $maxPerPid.Keys | Sort-Object { $maxPerPid[$_] } -Descending | Select-Object -First 6
    foreach ($k in $pids) {
        $p = Get-Process -Id $k -ErrorAction SilentlyContinue
        $path = ''
        if ($p) { try { $path = $p.Path } catch { $path = '' } }
        $top += [pscustomobject]@{
            Pid  = $k
            Name = $(if ($p) { $p.ProcessName } else { '(exited)' })
            Util = [math]::Round($maxPerPid[$k], 1)
            Path = $path
        }
    }
    $out.Top = $top
    return $out
}

function Get-EventsSafe {
    param([hashtable]$Filter, [int]$Max = 400)
    try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) } catch { return @() }
}

function Get-PowerIndex {
    param([string]$Sub, [string]$Setting)
    try { $raw = powercfg /query SCHEME_CURRENT $Sub $Setting 2>$null } catch { return $null }
    if (-not $raw) { return $null }
    $hex = [regex]::Matches(($raw -join ' '), '0x[0-9a-fA-F]{1,8}') | ForEach-Object { $_.Value }
    if ($hex.Count -lt 2) { return $null }
    try {
        return [pscustomobject]@{
            AC = [Convert]::ToInt32($hex[$hex.Count - 2], 16)
            DC = [Convert]::ToInt32($hex[$hex.Count - 1], 16)
        }
    } catch { return $null }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

# ----------------------------------------------------------------------------
# driver health: signatures, leftover driver-store packages, WU driver search
# ----------------------------------------------------------------------------
function Get-DriverStorePackages {
    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    $out = @()
    if (-not (Test-Path $repo)) { return $out }
    $patterns = @('nv_dispi.inf_amd64_*', 'nvhm*', 'nvaci*', 'amdkmpfd*', 'amdkmdag*', 'igdlh64*', 'iigd_*', 'u03*')
    foreach ($pat in $patterns) {
        $items = @(Get-ChildItem $repo -Directory -Filter $pat -ErrorAction SilentlyContinue)
        foreach ($i in $items) { $out += $i }
    }
    return $out
}

function Get-WuDriverUpdates {
    param([int]$TimeoutSeconds = 60)
    $res = [pscustomobject]@{ Ok = $false; Titles = @(); Detail = '' }
    $tmpPs1 = Join-Path $env:TEMP ('gpu-diag-wu-' + $PID + '.ps1')
    $tmpOut = Join-Path $env:TEMP ('gpu-diag-wu-' + $PID + '.json')
    $child = @'
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    try { $searcher.ServerSelection = 3 } catch { }
    $result = $searcher.Search("IsInstalled=0 AND Type='Driver'")
    $list = @()
    foreach ($u in $result.Updates) { $list += [pscustomobject]@{ title = $u.Title } }
    $json = ConvertTo-Json -InputObject @($list) -Compress -Depth 4
    [System.IO.File]::WriteAllText($args[0], $json, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    [System.IO.File]::WriteAllText($args[0], ('ERR:' + $_.Exception.Message), (New-Object System.Text.UTF8Encoding($false)))
}
'@
    try {
        [System.IO.File]::WriteAllText($tmpPs1, $child, (New-Object System.Text.UTF8Encoding($true)))
        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $tmpPs1, $tmpOut) -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch { }
            $res.Detail = "timed out after $TimeoutSeconds s"
            return $res
        }
        if (-not (Test-Path $tmpOut)) { $res.Detail = 'no answer from Windows Update'; return $res }
        $raw = [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8).Trim()
        if ($raw -like 'ERR:*') { $res.Detail = $raw.Substring(4); return $res }
        if (-not $raw) { $res.Ok = $true; return $res }
        $data = @($raw | ConvertFrom-Json)
        $titles = @()
        foreach ($d in $data) { if ($d.title) { $titles += [string]$d.title } }
        $res.Ok = $true
        $res.Titles = $titles
        return $res
    } catch {
        $res.Detail = $_.Exception.Message
        return $res
    } finally {
        Remove-Item $tmpPs1 -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
    }
}

function Get-DriverHealth {
    Hdr 'DRIVER HEALTH CHECK'
    $signed = @()
    try { $signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceClass -eq 'DISPLAY' }) } catch { }
    if ($signed.Count -eq 0) { W '  (signed-driver info for display class unavailable)' }
    foreach ($d in $signed) {
        W ("  * " + (Show $d.DeviceName))
        W ("      version  : {0}   provider: {1}" -f (Show $d.DriverVersion), (Show $d.DriverProviderName))
        W ("      date     : {0}   inf: {1}" -f $(if ($d.DriverDate) { ([datetime]$d.DriverDate).ToString('yyyy-MM-dd') } else { '?' }), (Show $d.InfName))
        W ("      signature: signed={0}  {1}" -f (Show $d.IsSigned), (Show $d.Signer))
        if ($d.IsSigned -eq $false) { Finding 'HIGH' ("Driver for '{0}' is not digitally signed - that is a real red flag." -f $d.DeviceName) }
    }

    $pkgs = @(Get-DriverStorePackages | Sort-Object LastWriteTime -Descending)
    KV 'GPU driver packages in store' $pkgs.Count
    foreach ($p in ($pkgs | Select-Object -First 8)) { W ("     {0}  (installed around {1:yyyy-MM-dd})" -f $p.Name, $p.LastWriteTime) }
    $nvPkgs = @($pkgs | Where-Object { $_.Name -like 'nv_dispi*' -or $_.Name -like 'nvhm*' -or $_.Name -like 'nvaci*' })
    $amdPkgs = @($pkgs | Where-Object { $_.Name -like 'amdkm*' -or $_.Name -like 'amdkmpfd*' })
    if ($nvPkgs.Count -gt 2 -or $amdPkgs.Count -gt 2) {
        Finding 'INFO' ("Several GPU driver packages are still in the driver store (NVIDIA: {0}, AMD: {1}) - leftovers of previous installs. If a clean reinstall is needed, use DDU / the vendor's 'clean install' option." -f $nvPkgs.Count, $amdPkgs.Count)
    }

    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations') { $pending = $true }
    KV 'Reboot pending' $pending
    if ($pending) { Finding 'LOW' 'Windows has a pending reboot (unfinished driver/update installation) - restart before judging the problem.' }

    Say '  checking Windows Update for driver updates (up to 60 s)...'
    $wu = Get-WuDriverUpdates -TimeoutSeconds 60
    if ($wu.Ok) {
        KV 'Driver updates offered by WU' $wu.Titles.Count
        foreach ($t in ($wu.Titles | Select-Object -First 6)) { W ("     * $t") }
        if ($wu.Titles.Count -gt 0) {
            Finding 'MEDIUM' ("Windows Update offers {0} driver update(s). For a graphics card the vendor's own installer with 'clean install' is the safer route than WU." -f $wu.Titles.Count)
        }
    } else {
        W ("  Windows Update driver search: skipped (" + (Show $wu.Detail) + ")")
    }
}


# ----------------------------------------------------------------------------
# live monitor (watch mode) helpers
# ----------------------------------------------------------------------------
function Add-Utf8Line {
    param([string]$Path, [string]$Line)
    try {
        [System.IO.File]::AppendAllText($Path, $Line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-ForegroundTitle {
    try {
        if (-not ('DiagNative' -as [type])) {
            Add-Type -Namespace '' -Name 'DiagNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int count);
'@ -ErrorAction Stop
        }
        $h = [DiagNative]::GetForegroundWindow()
        $sb = New-Object System.Text.StringBuilder 512
        [void][DiagNative]::GetWindowText($h, $sb, 512)
        return $sb.ToString().Replace("`r", ' ').Replace("`n", ' ')
    } catch { return '' }
}

function Get-ActiveMonitorCount {
    try {
        $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
        return @($m | Where-Object { $_.Active }).Count
    } catch { return -1 }
}

function Get-ThermalSample {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $temp = ''
    try {
        $z = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        if ($z.Count -gt 0) {
            $max = ($z | Measure-Object -Property CurrentTemperature -Maximum).Maximum
            $temp = [math]::Round(($max / 10) - 273.15, 1)
        }
    } catch { }
    $load = ''; $mhz = ''; $pct = ''
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop |
            Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        if ($p) { $load = $p.PercentProcessorTime; $mhz = $p.ProcessorFrequency; $pct = $p.PercentofMaximumFrequency }
    } catch { }
    return ('{0},{1},{2},{3},{4}' -f $stamp, $temp, $load, $mhz, $pct)
}

function Stop-WatchProcesses {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $flag = Join-Path $LogDir 'stop.flag'
    Set-Content -Path $flag -Value 'stop' -Encoding ASCII
    Start-Sleep -Seconds 3
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*GPU-Diag.ps1*' -and $_.CommandLine -like '*Watch*' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    } catch { }
}

function Get-WatchEvents {
    param([int64]$AfterRecordId)
    $providers = @('Display', 'nvlddmkm', 'amdkmdag', 'amdkmdap', 'igfx',
        'Microsoft-Windows-WHEA-Logger', 'Microsoft-Windows-Kernel-Power', 'BugCheck',
        'EventLog', 'Microsoft-Windows-Kernel-PnP', 'Microsoft-Windows-Kernel-LiveDump')
    $evts = Get-EventsSafe -Filter @{ LogName = 'System'; ProviderName = $providers; StartTime = (Get-Date).AddHours(-2) } -Max 300
    $extra = Get-EventsSafe -Filter @{ LogName = 'System'; Id = @(4101, 4102, 4103); StartTime = (Get-Date).AddHours(-2) } -Max 200
    $all = @()
    $seen = @{}
    foreach ($e in @($evts) + @($extra)) {
        if ($null -eq $e) { continue }
        if ($e.RecordId -le $AfterRecordId) { continue }
        if ($seen.ContainsKey($e.RecordId)) { continue }
        $seen[$e.RecordId] = $true
        $all += $e
    }
    return ($all | Sort-Object RecordId)
}

# ============================================================================
# REPORT
# ============================================================================
function Build-Report {
    $now = Get-Date

    W '=============================================================================='
    W '  GPU / DISPLAY DIAGNOSTIC REPORT'
    W '=============================================================================='
    KV 'Generated'    $now.ToString('yyyy-MM-dd HH:mm:ss')
    KV 'Tool version' $script:Version
    KV 'Computer'     $env:COMPUTERNAME
    KV 'User'         "$env:USERDOMAIN\$env:USERNAME"
    KV 'Admin rights' $isAdmin
    KV 'Times local'  ([System.TimeZoneInfo]::Local.DisplayName)

    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    Hdr 'OS / UPTIME'
    if ($os) {
        KV 'OS'          $os.Caption
        KV 'Version'     ("$($os.Version)" + $(if ($cv.DisplayVersion) { " ($($cv.DisplayVersion))" } else { '' }))
        KV 'Build'       ("$($cv.CurrentBuild).$($cv.UBR) $(if ($cv.CurrentBuild -ge 22000) { 'Win11' } else { 'Win10' })")
        KV 'Installed'   $(if ($os.InstallDate) { ([datetime]$os.InstallDate).ToString('yyyy-MM-dd') } else { '' })
        KV 'Last boot'   ([datetime]$os.LastBootUpTime).ToString('yyyy-MM-dd HH:mm:ss')
        KV 'Uptime'      ("{0:n1} hours" -f ((New-TimeSpan -Start $os.LastBootUpTime -End $now).TotalHours))
        KV 'RAM total'   ("{0:n1} GB" -f ($os.TotalVisibleMemorySize / 1MB))
        KV 'RAM free'    ("{0:n1} GB" -f ($os.FreePhysicalMemory / 1MB))
    }

    Hdr 'MACHINE'
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        KV 'Make / model' ("$($cs.Manufacturer) / $($cs.Model)")
    } catch { }
    try {
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        KV 'Motherboard'  ("$($bb.Manufacturer) $($bb.Product) $($bb.Version)")
    } catch { }
    try {
        $bio = Get-CimInstance Win32_BIOS -ErrorAction Stop
        KV 'BIOS'         $bio.SMBIOSBIOSVersion
        KV 'BIOS date'    $(if ($bio.ReleaseDate) { ([datetime]$bio.ReleaseDate).ToString('yyyy-MM-dd') } else { '' })
    } catch { }
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        KV 'CPU'          ("$($cpu.Name) [$($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T]")
    } catch { }
    try {
        $dimms = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        $i = 0
        foreach ($d in $dimms) {
            $i++
            KV "RAM module $i" ("{0:n0} GB  $($d.Speed)/$($d.ConfiguredClockSpeed) MHz  $($d.Manufacturer) $("$($d.PartNumber)".Trim())" -f ($d.Capacity / 1GB))
        }
        KV 'RAM modules'  $dimms.Count
    } catch { }
    $hiberboot = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    KV 'Fast Startup' $(if ($hiberboot -eq 1) { 'ON (HiberbootEnabled=1)' } elseif ($hiberboot -eq 0) { 'off' } else { 'default' })

    # ------------------------------------------------------------------ GPU
    $gpus = Get-Gpus
    Hdr 'GPU(S)'
    if ($gpus.Count -eq 0) { W '  (no video controller reported)' }
    $nvdia = $null
    foreach ($g in $gpus) {
        W "  * $($g.Name)  [$($g.Vendor)]"
        W ("      driver   : {0}  ({1})" -f (Show $g.DriverVer), $(if ($g.DriverDate) { ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') } else { 'unknown date' }))
        W ("      mode     : {0}   status: {1}" -f (Show $g.Resolution), (Show $g.Status))
        if ($g.Vendor -eq 'NVIDIA') { $nvdia = $g }
        if ($g.DriverDate) {
            $age = [int]((Get-Date) - [datetime]$g.DriverDate).TotalDays
            W ("      driver age: {0} days" -f $age)
            if ($age -gt 240) { Finding 'MEDIUM' "GPU driver for '$($g.Name)' is $age days old - clean-install the latest driver." }
        }
        if ($g.Name -match 'Basic Display|Basic Render') {
            Finding 'HIGH' "Windows has no real GPU driver installed ('$($g.Name)') - install the vendor driver."
        }
    }
    if ($gpus.Count -gt 1) {
        Finding 'INFO' ("Multiple video adapters detected ({0}). Make sure the monitor is plugged into the discrete GPU, not the motherboard." -f $gpus.Count)
    }

    Get-DriverHealth

    $mons = Get-Monitors
    Hdr 'MONITORS'
    if ($mons.Count -eq 0) { W '  (none reported - possibly a driver/EDID problem)' }
    foreach ($m in $mons) {
        W ("  * {0} {1}  s/n {2}  ({3})  {4}  {5}" -f $m.Maker, $m.Name, (Show $m.Serial), (Show $m.Year), $(if ($m.Active) { 'ACTIVE' } else { 'inactive' }), (Show $m.Tech))
    }
    $conns = @($mons | Where-Object { $_.Tech } | Select-Object -ExpandProperty Tech -Unique)
    if ($conns.Count -gt 0) { KV 'Connections' ($conns -join ', ') }
    if ($mons.Count -gt 1) {
        Finding 'LOW' "More than one monitor is connected - a useful test is to run a single monitor only."
    }

    Hdr 'DEVICE MANAGER PROBLEMS'
    $badDevices = @()
    try {
        $badDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -ne 'OK' })
    } catch { }
    $badGpu = @($badDevices | Where-Object { $_.Class -eq 'Display' -or "$($_.FriendlyName)" -match 'NVIDIA|Radeon|AMD |Intel\(R\) Graphics|Video Controller' })
    KV 'Devices with problems' $badDevices.Count
    if ($badDevices.Count -eq 0) { W '  no devices with a problem status' }
    foreach ($d in ($badDevices | Select-Object -First 12)) {
        W ("  ! {0}  [{1}] {2}  {3}" -f (Show $d.FriendlyName), $d.Status, $d.Class, $d.InstanceId)
    }
    if ($badDevices.Count -gt 12) { W ("  ... and {0} more" -f ($badDevices.Count - 12)) }
    if ($badGpu.Count -gt 0) {
        foreach ($d in $badGpu) { Finding 'HIGH' "Video-related device with an error state: $($d.FriendlyName) [$($d.Status)] - reinstall the GPU driver." }
    } elseif ($badDevices.Count -gt 0) {
        Finding 'LOW' ("Device Manager shows {0} device(s) with problems. Unnamed 'PCI device' entries are usually missing chipset drivers and are harmless; named devices deserve a look." -f $badDevices.Count)
    }

    # ------------------------------------------------------- current GPU load
    $smi = Get-NvSmiPath
    Hdr 'GPU LOAD RIGHT NOW (3 s sample, summed over GPU engines)'
    $load = Get-GpuLoad
    if ($load.Error) {
        W ("  counter unavailable: $($load.Error)")
    } else {
        KV 'Total engine util' ("$($load.Total) %")
        if ($load.Top.Count -eq 0) { W '  no process using the GPU at this moment' }
        foreach ($t in $load.Top) {
            W ("  pid {0,-6} {1,-16} {2,6} %   {3}" -f $t.Pid, $t.Name, $t.Util, (Show $t.Path))
        }
        foreach ($t in $load.Top) {
            if ($t.Util -lt 40) { continue }
            if ($t.Path -and ($t.Path -match '\\Temp\\' -or $t.Path -match '\\AppData\\Local\\Temp\\')) {
                Finding 'HIGH' "Heavy GPU process '$($t.Name)' ($($t.Util)%) runs from a temp folder: $($t.Path) - possible unwanted software."
            }
        }
    }
    $miners = @('xmrig', 'ethminer', 'nbminer', 'phoenixminer', 'lolminer', 't-rex', 'trex', 'gminer', 'cgminer',
        'bfgminer', 'nicehash', 'claymore', 'srbminer', 'teamredminer', 'nanominer', 'xmr-stak', 'wildrig', 'kryptex')
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($miners -contains $p.ProcessName.ToLower()) {
            Finding 'HIGH' "Process with a mining-tool name is running: $($p.ProcessName) (pid $($p.Id))."
        }
    }

    # ------------------------------------------------------------- NVIDIA live
    Hdr 'NVIDIA LIVE DATA (nvidia-smi)'
    if (-not $smi) {
        W '  nvidia-smi not found (not an NVIDIA GPU, or driver not installed).'
        W '  For AMD/Intel cards: check temperatures/power in Adrenalin / Intel Arc Control or GPU-Z.'
    } else {
        KV 'nvidia-smi' $smi
        $gpuList = @(& $smi '--list-gpus' 2>$null)
        if ($gpuList.Count -gt 0) { W ("  NVIDIA GPUs visible: " + ($gpuList -join ' | ')) }
        $s = Get-NvSample -Smi $smi
        if ($s) {
            KV 'GPU'            $s.Name
            KV 'Driver'         $s.Driver
            KV 'Temperature'    ("$($s.Temp) C")
            KV 'Utilisation'    ("gpu $($s.UtilGpu) %   mem $($s.UtilMem) %")
            KV 'Memory used'    ("$($s.MemUsed) MB")
            KV 'Power draw/limit' ("$($s.Power) W / $($s.PowerLimit) W")
            KV 'Clocks'         ("core $($s.ClockSm) MHz   mem $($s.ClockMem) MHz")
            KV 'Fan'            ("$($s.Fan) %")
            KV 'P-state'        $s.PState
            KV 'Throttle bits'  ("$($s.Throttle)  => $(Convert-ThrottleBits $s.Throttle)")
            $tn = Convert-ThrottleBits $s.Throttle
            if ($tn -match 'HwSlowdown|HwThermal|SwThermal|HwPowerBrake') {
                Finding 'MEDIUM' "GPU reports thermal/power throttling right now ($tn) - cooling or power delivery should be checked."
            }
            if ($s.Temp -match '^\d+$' -and [int]$s.Temp -ge 80) {
                Finding 'MEDIUM' "GPU temperature is $($s.Temp) C at idle-ish load - check fans, dust, airflow."
            }
        } else {
            W '  nvidia-smi returned no data.'
        }
        $pcie = Get-NvRaw -Smi $smi -Query 'pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max'
        if ($pcie -and $pcie.Count -ge 4) {
            KV 'PCIe link' ("gen $($pcie[0]) (max $($pcie[1]))  x$($pcie[2]) (max x$($pcie[3]))")
            if ($pcie[0] -match '^\d+$' -and $pcie[1] -match '^\d+$' -and [int]$pcie[0] -lt [int]$pcie[1] -and [int]$pcie[0] -le 2) {
                Finding 'MEDIUM' "PCIe link dropped to gen $($pcie[0]) (max gen $($pcie[1])) - this points at the slot, riser, GPU seating or power delivery."
            }
        }
        $xid = Get-NvRaw -Smi $smi -Query 'retired_pages.pending'
        if ($xid) { KV 'Retired pages pending' $xid }
    }

    # ------------------------------------------------------------ cpu / thermal
    Hdr 'CPU / THERMAL CHECK'
    $cpuInfo = $null
    try { $cpuInfo = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }
    if ($cpuInfo) {
        KV 'CPU'             $cpuInfo.Name
        KV 'Cores / threads' ("$($cpuInfo.NumberOfCores) / $($cpuInfo.NumberOfLogicalProcessors)")
        KV 'Nominal clock'   ("$($cpuInfo.MaxClockSpeed) MHz")
    }
    $perfCpu = $null
    try {
        $perfCpu = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop |
            Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    } catch { }
    if ($perfCpu) {
        KV 'CPU load now'    ("$($perfCpu.PercentProcessorTime) %")
        KV 'Current clock'   ("$($perfCpu.ProcessorFrequency) MHz  ($($perfCpu.PercentofMaximumFrequency) % of max)")
        $pctMax = 0
        try { $pctMax = [int]$perfCpu.PercentofMaximumFrequency } catch { }
        if ($pctMax -gt 0 -and $pctMax -lt 85) {
            Finding 'MEDIUM' ("CPU is running at {0}% of its maximum frequency right now - that is firmware throttling (thermal or power limit)." -f $pctMax)
        }
    }
    $zones = @()
    try { $zones = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop) } catch { }
    if ($zones.Count -eq 0) {
        W '  CPU temperature: not exposed through ACPI on this board (very common on desktops).'
        W '  Real core temperatures need HWiNFO / LibreHardwareMonitor or the BIOS screen.'
    } else {
        foreach ($z in $zones) {
            $c = [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1)
            KV ("Thermal zone " + $z.InstanceName) ("$c C")
            if ($c -ge 90) { Finding 'HIGH' ("ACPI thermal zone '{0}' reports {1} C - cooling is not keeping up." -f $z.InstanceName, $c) }
        }
    }
    $tpow = Get-EventsSafe -Filter @{ LogName = 'System'; ProviderName = @('Microsoft-Windows-Kernel-Processor-Power'); StartTime = (Get-Date).AddDays(-30) } -Max 300
    $throttle = @($tpow | Where-Object { $_.Id -eq 37 })
    KV 'Firmware CPU throttle events (30 d)' $throttle.Count
    foreach ($e in ($throttle | Select-Object -Last 5)) {
        $msg = "$($e.Message)" -replace "`r", ' ' -replace "`n", ' '
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
        W ("     {0}  {1}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $msg)
    }
    if ($throttle.Count -gt 0) {
        Finding 'HIGH' ("Windows logged {0} 'processor speed limited by firmware' event(s) - the CPU is thermally or power throttling." -f $throttle.Count)
    }

    # ---------------------------------------------------------- power settings
    Hdr 'POWER SETTINGS'
    $schemeLine = try { (powercfg /getactivescheme 2>$null) -join ' ' } catch { '' }
    $schemeGuid = ''
    if ($schemeLine -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $schemeGuid = $Matches[1] }
    KV 'Active power plan' $schemeLine

    $aspm   = Get-PowerIndex $PC.PcieSub $PC.PcieAsm
    $vidle  = Get-PowerIndex $PC.VideoSub $PC.VideoIdle
    $usbsus = Get-PowerIndex $PC.UsbSub $PC.UsbSus
    $sleep  = Get-PowerIndex $PC.SleepSub $PC.SleepIdle

    if ($aspm) {
        KV 'PCIe link power saving (ASPM)' ("AC=" + $(if ($aspm.AC -eq 0) { 'Off' } else { $aspm.AC }) + "  DC=" + $(if ($aspm.DC -eq 0) { 'Off' } else { $aspm.DC }))
        if ($aspm.AC -ne 0) { Finding 'MEDIUM' 'PCIe ASPM power saving is enabled - a classic cause of random display drop-outs. (Fix option can turn it off.)' }
    } else { KV 'PCIe ASPM' 'not configured (default)' }
    if ($vidle) {
        KV 'Turn off display after (AC)' $(if ($vidle.AC -eq 0) { 'Never' } else { "$([int]($vidle.AC / 60)) min" })
        if ($vidle.AC -gt 0 -and $vidle.AC -le 600) {
            Finding 'MEDIUM' "Windows turns the display off after $([int]($vidle.AC / 60)) min on AC power - rule this out by setting it to Never."
        }
    }
    if ($usbsus) {
        KV 'USB selective suspend (AC)' $(if ($usbsus.AC -eq 0) { 'Disabled' } else { 'Enabled' })
    }
    if ($sleep) {
        KV 'Sleep after (AC)' $(if ($sleep.AC -eq 0) { 'Never' } else { "$([int]($sleep.AC / 60)) min" })
    }
    if ($hiberboot -eq 1) {
        Finding 'LOW' 'Fast Startup is ON - it keeps driver state across reboots and hides driver problems. (Fix option can turn it off.)'
    }

    # ------------------------------------------------------ graphics registry
    Hdr 'GRAPHICS / DRIVER REGISTRY'
    $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $tdrDelay = Get-RegValue $gd 'TdrDelay'
    $tdrDdi   = Get-RegValue $gd 'TdrDdiDelay'
    $tdrLevel = Get-RegValue $gd 'TdrLevel'
    $hwSch    = Get-RegValue $gd 'HwSchMode'
    KV 'TdrDelay'    $(if ($null -eq $tdrDelay) { 'default (2 s)' } else { "$tdrDelay s" })
    KV 'TdrDdiDelay' $(if ($null -eq $tdrDdi) { 'default (5 s)' } else { "$tdrDdi s" })
    KV 'TdrLevel'    $(if ($null -eq $tdrLevel) { 'default (3 = recover)' } else { "$tdrLevel" })
    KV 'HwSchMode (HAGS)' $(switch ($hwSch) { 2 { 'enabled' } 1 { 'disabled' } default { 'default/unknown' } })
    if ($tdrLevel -eq 0) {
        Finding 'HIGH' 'TdrLevel=0 is set: driver timeout recovery is DISABLED, so a driver hang freezes the picture until reboot. (Fix option resets this.)'
    }
    if ($tdrDelay -ne $null -and $tdrDelay -gt 2) {
        Finding 'INFO' "TdrDelay was already raised to $tdrDelay s - somebody fought this problem before."
    }
    $nv = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm' -ErrorAction SilentlyContinue
    if ($nv) { KV 'nvlddmkm ImagePath' $nv.ImagePath }

    # ----------------------------------------------------------------- events
    Hdr 'SYSTEM EVENT LOG (last 30 days)'
    $start = (Get-Date).AddDays(-30)
    $providers = @('Display', 'nvlddmkm', 'amdkmdag', 'amdkmdap', 'igfx', 'igfxn',
        'Microsoft-Windows-WHEA-Logger', 'Microsoft-Windows-Kernel-Power', 'BugCheck',
        'EventLog', 'Microsoft-Windows-Kernel-PnP', 'Microsoft-Windows-Kernel-LiveDump')
    $evByProvider = Get-EventsSafe -Filter @{ LogName = 'System'; ProviderName = $providers; StartTime = $start } -Max 3000
    $evById       = Get-EventsSafe -Filter @{ LogName = 'System'; Id = @(4101, 4102, 4103); StartTime = $start } -Max 3000
    $allEvents = @()
    $seen = @{}
    foreach ($e in (@($evByProvider) + @($evById))) {
        if ($null -eq $e) { continue }
        if ($seen.ContainsKey($e.RecordId)) { continue }
        $seen[$e.RecordId] = $true
        $allEvents += $e
    }
    $allEvents = @($allEvents | Sort-Object TimeCreated)

    W ("  relevant events found: {0}" -f $allEvents.Count)
    if ($allEvents.Count -gt 0) {
        W ''
        W '  -- summary (provider / id / level / count / first / last)'
        $groups = $allEvents | Group-Object { "$($_.ProviderName) / $($_.Id) / $($_.LevelDisplayName)" } | Sort-Object Count -Descending
        foreach ($gr in $groups) {
            $f = ($gr.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
            $l = ($gr.Group | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated
            W ("     {0,-52} {1,5}   {2}  ..  {3}" -f $gr.Name, $gr.Count, $f.ToString('yyyy-MM-dd HH:mm'), $l.ToString('yyyy-MM-dd HH:mm'))
        }
        W ''
        W '  -- last 30 events, newest last'
        foreach ($e in ($allEvents | Select-Object -Last 30)) {
            $msg = "$($e.Message)"
            $msg = ($msg -replace "`r", ' ' -replace "`n", ' ')
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
            W ("     {0}  [{1}] id={2} ({3})  {4}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.ProviderName, $e.Id, $e.LevelDisplayName, $msg)
        }
    }

    $displayFail = @($allEvents | Where-Object { $_.ProviderName -in @('Display', 'nvlddmkm', 'amdkmdag', 'amdkmdap', 'igfx') -or $_.Id -in @(4101, 4102, 4103) })
    $whea  = @($allEvents | Where-Object { $_.ProviderName -like '*WHEA*' })
    $kp41  = @($allEvents | Where-Object { $_.ProviderName -like '*Kernel-Power*' -and $_.Id -eq 41 })
    $bugs  = @($allEvents | Where-Object { $_.ProviderName -eq 'BugCheck' -or $_.Id -eq 1001 })
    $unexp = @($allEvents | Where-Object { $_.Id -eq 6008 })
    $pnp   = @($allEvents | Where-Object { $_.ProviderName -like '*Kernel-PnP*' })

    KV 'Display driver resets (TDR)' $displayFail.Count
    KV 'WHEA hardware errors'        $whea.Count
    KV 'Kernel-Power 41 (power loss)' $kp41.Count
    KV 'BSOD (BugCheck)'             $bugs.Count
    KV 'Unexpected shutdown (6008)'  $unexp.Count
    KV 'Kernel-PnP problems'         $pnp.Count

    if ($displayFail.Count -gt 0) {
        Finding 'HIGH' ("Display driver reset/error events: {0} in 30 days. That is the classic signature of a driver/GPU/PSU problem behind 'monitor goes black while GPU is loaded'." -f $displayFail.Count)
    }
    if ($whea.Count -gt 0) {
        Finding 'HIGH' ("WHEA hardware error events: {0}. This is the machine reporting a hardware-level fault (PCIe bus, CPU, RAM, power). Not a monitor problem." -f $whea.Count)
    }
    if ($kp41.Count -gt 0) {
        Finding 'HIGH' ("Kernel-Power 41: {0} unplanned power loss(es). Suspect the power supply, GPU power cables, or an unstable overclock." -f $kp41.Count)
    }
    if ($bugs.Count -gt 0) { Finding 'HIGH' ("BSOD / BugCheck events: {0}. Look at the dump files below." -f $bugs.Count) }
    if ($pnp.Count -gt 0) { Finding 'MEDIUM' ("Kernel-PnP events: {0}. A device (often the GPU) is failing to start or is being reset by Windows." -f $pnp.Count) }
    if ($allEvents.Count -eq 0) {
        Finding 'INFO' 'No display/power/hardware events in the System log for the last 30 days. Either the problem is very recent, the log was cleared, or Windows records nothing until the background logger is running.'
    }

    # ------------------------------------------------------------ crash dumps
    Hdr 'CRASH DUMPS / LIVE KERNEL REPORTS'
    $mk = 'C:\Windows\Minidump'
    $mds = @()
    if (Test-Path $mk) { $mds = @(Get-ChildItem $mk -Filter '*.dmp' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) }
    KV 'Minidumps' $mds.Count
    foreach ($d in ($mds | Select-Object -First 8)) { W ("     {0}  {1:n1} MB" -f $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), ($d.Length / 1MB)) }
    if ($mds.Count -gt 0) { Finding 'HIGH' "$($mds.Count) minidump(s) found - the PC has crashed and rebooted, which the owner may not have noticed." }

    $lkr = 'C:\Windows\LiveKernelReports'
    $lkrFiles = @()
    if (Test-Path $lkr) { $lkrFiles = @(Get-ChildItem $lkr -Recurse -File -Include '*.dmp', '*.etl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) }
    KV 'Live kernel reports' $lkrFiles.Count
    foreach ($d in ($lkrFiles | Select-Object -First 10)) { W ("     {0}  {1:n1} MB  {2}" -f $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), ($d.Length / 1MB), $d.FullName) }
    if ($lkrFiles.Count -gt 0) {
        Finding 'HIGH' "Live kernel dump(s) present. A WATCHDOG dump means the display engine stopped responding (VIDEO_ENGINE_TIMEOUT / 0x141) - driver, GPU or power, not the monitor cable alone."
    }

    # ------------------------------------------------- background app crashes
    Hdr 'APPLICATION LOG - GRAPHICS RELATED'
    $relApp = @(Get-EventsSafe -Filter @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); StartTime = $start } -Max 500 |
        Where-Object { "$($_.Message)" -match 'nvcontainer|nvdisplay|nvspcaps|nvwgf2umx|nvoglv|amdkmdag|RadeonSoftware|igfx|dwm\.exe|dwmcore' })
    KV 'Graphics app crashes/hangs' $relApp.Count
    foreach ($e in ($relApp | Select-Object -Last 10)) {
        $msg = "$($e.Message)" -replace "`r", ' ' -replace "`n", ' '
        if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
        W ("     {0}  id={1}  {2}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $e.Id, $msg)
    }
    if ($relApp.Count -gt 0) { Finding 'MEDIUM' 'Graphics-related application crashes/hangs in the log - usually the same driver issue.' }

    # live kernel events / BSODs as reported by Windows Error Reporting
    $wer = @(Get-EventsSafe -Filter @{ LogName = 'Application'; ProviderName = @('Windows Error Reporting'); Id = @(1001); StartTime = $start } -Max 800 |
        Where-Object { "$($_.Message)" -match 'LiveKernelEvent|BlueScreen' })
    $signatures = @{}
    foreach ($e in $wer) {
        $m = [regex]::Match("$($e.Message)", 'P1:\s*([0-9a-fA-F]+)')
        $code = '?'
        if ($m.Success) { $code = $m.Groups[1].Value }
        $kind = 'BlueScreen'
        if ("$($e.Message)" -match 'LiveKernelEvent') { $kind = 'LiveKernel' }
        $key = "$kind P1=$code"
        if ($signatures.ContainsKey($key)) { $signatures[$key] = @($signatures[$key]) + @($e.TimeCreated) }
        else { $signatures[$key] = @($e.TimeCreated) }
    }
    KV 'WER LiveKernel/BSOD records' $wer.Count
    foreach ($k in ($signatures.Keys | Sort-Object)) {
        $times = @($signatures[$k] | Sort-Object)
        W ("     {0,-26} x{1}   last {2}" -f $k, $times.Count, $times[-1].ToString('yyyy-MM-dd HH:mm'))
    }
    $engineTimeout = @($signatures.Keys | Where-Object { $_ -match 'P1=(141|117)$' })
    if ($engineTimeout.Count -gt 0) {
        Finding 'HIGH' 'Windows recorded display-engine timeouts (LiveKernelEvent 141/117 = video engine stopped responding). That is driver, GPU or power delivery - not the monitor.'
    } elseif ($wer.Count -gt 0) {
        Finding 'MEDIUM' ("Windows recorded {0} live-kernel/BSOD error report(s) - see the signature list above." -f $wer.Count)
    }

    # -------------------------------------------------------- OC / monitoring
    Hdr 'BACKGROUND SOFTWARE THAT CAN AFFECT THE DISPLAY'
    $watchNames = @{
        'MSIAfterburner' = 'MSI Afterburner (GPU overclock)'; 'RTSS' = 'RivaTuner Statistics Server (overlay)'
        'RivaTuner'      = 'RivaTuner'; 'PrecisionX_x64' = 'EVGA Precision X'; 'PrecisionXServer' = 'EVGA Precision X'
        'GPU_Tweak'      = 'ASUS GPU Tweak'; 'ArmouryCrate.UserSessionHelper' = 'Armoury Crate'
        'iCUE'           = 'Corsair iCUE'; 'CAM' = 'NZXT CAM'; 'HWiNFO64' = 'HWiNFO'
        'GPU-Z'          = 'GPU-Z'; 'wallpaper32' = 'Wallpaper Engine'; 'wallpaper64' = 'Wallpaper Engine'
        'nvcontainer'    = 'NVIDIA container'; 'nvsphelper64' = 'NVIDIA ShadowPlay helper'
        'Overwolf'       = 'Overwolf overlay'; 'Discord' = 'Discord overlay (if enabled)'
        'nvidia share'   = 'NVIDIA Share overlay'; 'LogitechLedMon' = 'Logitech LED'
        'OpenHardwareMonitor' = 'Open Hardware Monitor'; 'LibreHardwareMonitor' = 'Libre Hardware Monitor'
        'MSI_Afterburner' = 'MSI Afterburner'
    }
    $running = @(Get-Process -ErrorAction SilentlyContinue)
    $hits = @()
    foreach ($p in $running) {
        if ($watchNames.ContainsKey($p.ProcessName)) { $hits += $watchNames[$p.ProcessName] }
    }
    $hits = @($hits | Sort-Object -Unique)
    if ($hits.Count -eq 0) { W '  none of the usual suspects is running' } else { foreach ($h in $hits) { W "  * $h" } }
    if ($hits -match 'Afterburner|Precision|GPU Tweak|RivaTuner') {
        Finding 'MEDIUM' 'GPU overclocking / overlay software is running. Test with it fully closed (overclocks and overlays both cause display drop-outs).'
    }

    Hdr 'AUTOSTART ENTRIES'
    try {
        $st = Get-CimInstance Win32_StartupCommand -ErrorAction Stop
        foreach ($s in $st) { W ("  {0,-22} {1}" -f $s.Name, (Show $s.Command)) }
        KV 'Autostart items' $st.Count
    } catch { W '  (unavailable)' }

    # -------------------------------------------------------------- findings
    Hdr 'FINDINGS / LIKELY CAUSES'
    if ($script:Findings.Count -eq 0) {
        W '  Nothing obviously wrong was found in the static data.'
        W '  For an intermittent problem, run the background logger and catch the moment it happens.'
    } else {
        foreach ($f in $script:Findings) { W "  $f" }
    }

    Hdr 'WHAT WAS CHECKED (for the person reading this)'
    W '  - Video adapter(s), driver version/date, current mode and refresh rate'
    W '  - Driver health: digital signature, driver-store leftovers, pending reboot,'
    W '    Windows Update driver search (report only, nothing is installed)'
    W '  - Monitor identity, year of manufacture and the physical connection type (HDMI / DisplayPort / ...)'
    W '  - Device Manager problem devices'
    W '  - Live GPU load per process (and unsigned/temp-folder heavy processes)'
    W '  - nvidia-smi live values (temperature, power, clocks, throttling, PCIe link)'
    W '  - Power plan: PCIe ASPM, display/ sleep timeouts, USB selective suspend, Fast Startup'
    W '  - Graphics registry: TDR settings, hardware GPU scheduling'
    W '  - Last 30 days of System + Application events (display driver resets, WHEA, Kernel-Power 41, BSOD, PnP)'
    W '  - Minidumps and LiveKernelReports (WATCHDOG = display engine timeout)'
    W '  - Overclocking/overlay software and autostart entries'

    W ''
    W '=============================================================================='
    W '  END OF REPORT'
    W '=============================================================================='
}

# ----------------------------------------------------------------------------
# package (report + logs + dumps -> zip on Desktop)
# ----------------------------------------------------------------------------
function Copy-LogsTo {
    param([string]$Dest)
    if (-not (Test-Path $LogDir)) { return }
    $w = Join-Path $Dest 'watch'
    New-Item -ItemType Directory -Force -Path $w | Out-Null
    Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.csv', '.log', '.json' } |
        ForEach-Object {
            try { Copy-Item $_.FullName -Destination (Join-Path $w $_.Name) -Force -ErrorAction Stop } catch { }
        }
}

function Export-RawEvents {
    param([string]$Dest)
    $sys = Join-Path $Dest 'System.evtx'
    if ($isAdmin) {
        try { & wevtutil epl System "$sys" 2>$null } catch { }
        if (Test-Path $sys) {
            if ((Get-Item $sys).Length -gt 120MB) { Remove-Item $sys -Force -ErrorAction SilentlyContinue }
        }
    }
    $md = 'C:\Windows\Minidump'
    if (Test-Path $md) {
        $dumps = @(Get-ChildItem $md -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5)
        if ($dumps.Count -gt 0) {
            $d = Join-Path $Dest 'minidumps'
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            foreach ($f in $dumps) { try { Copy-Item $f.FullName -Destination $d -Force -ErrorAction Stop } catch { } }
        }
    }
    $lkr = 'C:\Windows\LiveKernelReports'
    if (Test-Path $lkr) {
        try {
            Get-ChildItem $lkr -Recurse -File -Include '*.dmp', '*.etl' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 20 |
                ForEach-Object {
                    $line = '{0}  {1:n1} MB  {2}' -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), ($_.Length / 1MB), $_.FullName
                    [System.IO.File]::AppendAllText((Join-Path $Dest 'live-kernel-reports.txt'), $line + "`r`n")
                }
        } catch { }
    }
}

function New-DiagPackage {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $work = Join-Path $OutRoot ("run-$stamp")
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    Say ''
    Say 'Collecting data, please wait ~30 seconds...'
    $script:Rep.Clear()
    $script:Findings.Clear()
    Build-Report

    [System.IO.File]::WriteAllText((Join-Path $work 'report.txt'), ($script:Rep -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    Copy-LogsTo -Dest $work
    Export-RawEvents -Dest $work
    $selfCopy = Join-Path $work 'GPU-Diag.ps1'
    try { Copy-Item $PSCommandPath -Destination $selfCopy -Force -ErrorAction Stop } catch { }
    Copy-Item (Join-Path $PSScriptRoot 'README-RU.txt') -Destination (Join-Path $work 'README-RU.txt') -Force -ErrorAction SilentlyContinue

    $desk = [Environment]::GetFolderPath('Desktop')
    $zip = Join-Path $desk ("GPU-DIAG-" + $env:COMPUTERNAME + '-' + $stamp + '.zip')
    try {
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force -ErrorAction Stop
    } catch {
        Say (" [!] Could not create the ZIP: " + $_.Exception.Message)
        $zip = $work
    }

    Say ''
    Say '============================== FINDINGS =============================='
    if ($script:Findings.Count -eq 0) {
        Say ' Nothing obviously wrong found in the static data.'
        Say ' Run the background monitoring (menu 2) to catch the moment of the drop-out.'
    } else {
        foreach ($f in $script:Findings) { Say (' ' + $f) }
    }
    Say '====================================================================='
    Say ''
    if (Test-Path $zip -PathType Leaf) {
        Say (" Report + logs packed into:") 
        Say ("   $zip")
        Say ''
        Say ' SEND THAT ZIP FILE BACK. It contains report.txt and everything else needed.'
    } else {
        Say (" Folder with all files: $zip")
        Say ' Send the whole folder back.'
    }
    return $zip
}

# ----------------------------------------------------------------------------
# fixes
# ----------------------------------------------------------------------------
function Invoke-Fix {
    param([switch]$AssumeYes)
    if (-not $isAdmin) { Say ' [!] Admin rights are required for the fixes.'; return $false }
    Say ''
    Say 'The following SAFE and REVERSIBLE changes will be made:'
    Say '  1. PCIe link power saving (ASPM)  -> Off      (classic cause of display drops)'
    Say '  2. USB selective suspend          -> Disabled'
    Say '  3. Turn off display on AC power   -> Never    (rules out display sleep)'
    Say '  4. Fast Startup                   -> Off      (stops stale driver state)'
    Say '  5. TDR delay 2 s -> 10 s          (a driver hang recovers instead of freezing)'
    Say ''
    if (-not $AssumeYes) {
        $a = Read-Host 'Apply these changes? (y/n)'
        if ($a -notmatch '^(y|yes)$') { Say ' Cancelled.'; return $false }
    }

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $backup = [ordered]@{
        created      = (Get-Date).ToString('s')
        aspm         = Get-PowerIndex $PC.PcieSub $PC.PcieAsm
        videoIdle    = Get-PowerIndex $PC.VideoSub $PC.VideoIdle
        usbSuspend   = Get-PowerIndex $PC.UsbSub $PC.UsbSus
        hiberboot    = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
        tdrDelay     = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay'
        tdrDdiDelay  = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDdiDelay'
        tdrLevel     = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrLevel'
    }
    $bkPath = Join-Path $LogDir 'fix-backup.json'
    [System.IO.File]::WriteAllText($bkPath, ($backup | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Say (" Backup of original values: $bkPath")

    $steps = @(
        @{ Name = 'PCIe ASPM off';                       Cmd = { powercfg /setacvalueindex SCHEME_CURRENT $PC.PcieSub $PC.PcieAsm 0; powercfg /setdcvalueindex SCHEME_CURRENT $PC.PcieSub $PC.PcieAsm 0 } },
        @{ Name = 'USB selective suspend off';           Cmd = { powercfg /setacvalueindex SCHEME_CURRENT $PC.UsbSub $PC.UsbSus 0 } },
        @{ Name = 'Display never turns off (AC)';        Cmd = { powercfg /setacvalueindex SCHEME_CURRENT $PC.VideoSub $PC.VideoIdle 0 } },
        @{ Name = 'Activate power plan';                 Cmd = { powercfg /setactive SCHEME_CURRENT } },
        @{ Name = 'Fast Startup off';                    Cmd = { Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 -Type DWord } },
        @{ Name = 'TDR delay 10 s';                      Cmd = { Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay' 10 -Type DWord; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDdiDelay' 5 -Type DWord } }
    )
    foreach ($s in $steps) {
        try {
            & $s.Cmd | Out-Null
            Say (" [ok]   " + $s.Name)
        } catch {
            Say (" [fail] " + $s.Name + "  -> " + $_.Exception.Message)
        }
    }
    Say ''
    Say ' Done. RESTART THE PC for the TDR and Fast Startup changes to take effect.'
    Say ' The "Undo safe fixes" menu item restores the original values at any time.'
    return $true
}

function Invoke-Revert {
    if (-not $isAdmin) { Say ' [!] Admin rights are required.'; return }
    $bkPath = Join-Path $LogDir 'fix-backup.json'
    if (-not (Test-Path $bkPath)) { Say ' No backup found - nothing to undo.'; return }
    $b = Get-Content $bkPath -Raw | ConvertFrom-Json
    Say (" Restoring values saved on " + $b.created)
    $restorePower = {
        param($sub, $setting, $val)
        if ($null -eq $val) { return }
        powercfg /setacvalueindex SCHEME_CURRENT $sub $setting ($val.AC) | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT $sub $setting ($val.DC) | Out-Null
    }
    try { & $restorePower $PC.PcieSub $PC.PcieAsm $b.aspm;                     Say ' [ok]   PCIe ASPM restored' } catch { Say (' [fail] ASPM: ' + $_.Exception.Message) }
    try { & $restorePower $PC.VideoSub $PC.VideoIdle $b.videoIdle;             Say ' [ok]   display timeout restored' } catch { Say (' [fail] VIDEOIDLE: ' + $_.Exception.Message) }
    try { & $restorePower $PC.UsbSub $PC.UsbSus $b.usbSuspend;                 Say ' [ok]   USB suspend restored' } catch { Say (' [fail] USB: ' + $_.Exception.Message) }
    try { powercfg /setactive SCHEME_CURRENT | Out-Null } catch { }
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    if ($null -ne $b.hiberboot) { try { Set-ItemProperty $p 'HiberbootEnabled' ([int]$b.hiberboot) -Type DWord; Say ' [ok]   Fast Startup restored' } catch { } } else { try { Remove-ItemProperty $p 'HiberbootEnabled' -ErrorAction SilentlyContinue } catch { } }
    $g = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    foreach ($pair in @(@('TdrDelay', $b.tdrDelay), @('TdrDdiDelay', $b.tdrDdiDelay), @('TdrLevel', $b.tdrLevel))) {
        $name = $pair[0]; $val = $pair[1]
        try {
            if ($null -ne $val) { Set-ItemProperty $g $name ([int]$val) -Type DWord }
            else { Remove-ItemProperty $g $name -ErrorAction SilentlyContinue }
        } catch { }
    }
    Say ' [ok]   TDR values restored'
    Say ''
    Say ' Restart the PC to apply.'
}

# ----------------------------------------------------------------------------
# watch mode
# ----------------------------------------------------------------------------
function Invoke-InstallWatch {
    if (-not $isAdmin) { Say ' [!] Admin rights are required to register the background task.'; return }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Say ' Stopping a previously running logger (if any)...'
    Stop-WatchProcesses
    $stopFlag = Join-Path $LogDir 'stop.flag'
    if (Test-Path $stopFlag) { Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Watch')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {
        Say (' [!] Could not register the scheduled task: ' + $_.Exception.Message)
        Say '     Starting the logger for this session only instead.'
    }
    try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Watch') -WindowStyle Hidden
    }
    Say ''
    Say ' Background monitoring is ON.'
    Say (" Logs: " + $LogDir)
    Say ' Leave the PC running normally. When the monitor drops out again, the'
    Say ' moment and the GPU values around it will be recorded.'
    Say ' Then choose menu 3 (stop + final report) and send the ZIP.'
}

function Invoke-UninstallWatch {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Set-Content -Path (Join-Path $LogDir 'stop.flag') -Value 'stop' -Encoding ASCII
    Start-Sleep -Seconds 3
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Say ' [ok] background task removed' } catch { Say ' [--] background task was not registered' }
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*GPU-Diag.ps1*' -and $_.CommandLine -like '*Watch*' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    } catch { }
    Say ' Background monitoring stopped. Logs are kept.'
}

function Invoke-Watch {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $csv      = Join-Path $LogDir 'gpu-watch.csv'
    $thermCsv = Join-Path $LogDir 'thermal.csv'
    $evPath   = Join-Path $LogDir 'events.log'
    $stateF   = Join-Path $LogDir 'state.json'
    $stopFlag = Join-Path $LogDir 'stop.flag'
    $errPath  = Join-Path $LogDir 'watch-errors.log'
    if (Test-Path $stopFlag) { Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue }

    $header = 'timestamp,gpu,driver,temp_c,util_gpu_pct,util_mem_pct,mem_used_mb,power_w,power_limit_w,sm_clock_mhz,mem_clock_mhz,fan_pct,pstate,throttle_bits,throttle_names,monitors,active_window'
    if (-not (Test-Path $csv) -or (Get-Item $csv).Length -eq 0) { Add-Utf8Line -Path $csv -Line $header }
    if (-not (Test-Path $thermCsv) -or (Get-Item $thermCsv).Length -eq 0) {
        Add-Utf8Line -Path $thermCsv -Line 'timestamp,cpu_temp_c,cpu_load_pct,cpu_mhz,cpu_pct_of_max'
    }

    $lastId = 0
    if (Test-Path $stateF) {
        try { $lastId = [int64](Get-Content $stateF -Raw | ConvertFrom-Json).lastRecordId } catch { $lastId = 0 }
    }
    if ($lastId -eq 0) {
        try { $lastId = [int64](Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction Stop).RecordId } catch { $lastId = 0 }
    }
    $smi = Get-NvSmiPath
    Add-Utf8Line -Path $evPath -Line ("{0}  ---- logger started (nvidia-smi: {1}) ----" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), (Show $smi))

    $i = 0
    $monCount = -1
    while ($true) {
        if (Test-Path $stopFlag) { break }
        try {
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            if ($i % 6 -eq 0) { $monCount = Get-ActiveMonitorCount }
            Add-Utf8Line -Path $thermCsv -Line (Get-ThermalSample)
            $win = Get-ForegroundTitle
            $s = Get-NvSample -Smi $smi
            if ($s) {
                $vals = @($stamp, $s.Name, $s.Driver, $s.Temp, $s.UtilGpu, $s.UtilMem, $s.MemUsed, $s.Power,
                    $s.PowerLimit, $s.ClockSm, $s.ClockMem, $s.Fan, $s.PState, $s.Throttle,
                    (Convert-ThrottleBits $s.Throttle), $monCount)
            } else {
                $vals = @($stamp) + (@('') * 15)
                $vals[15] = $monCount
            }
            $line = ($vals -join ',') + ',"' + ($win -replace '"', "'") + '"'
            Add-Utf8Line -Path $csv -Line $line

            if ($i % 6 -eq 0) {
                $new = @(Get-WatchEvents -AfterRecordId $lastId)
                foreach ($e in $new) {
                    if ($e.RecordId -gt $lastId) { $lastId = $e.RecordId }
                    $msg = "$($e.Message)" -replace "`r", ' ' -replace "`n", ' '
                    if ($msg.Length -gt 700) { $msg = $msg.Substring(0, 700) + '...' }
                    Add-Utf8Line -Path $evPath -Line ('{0}  [{1}] id={2} ({3})  {4}' -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.ProviderName, $e.Id, $e.LevelDisplayName, $msg)
                }
                if ($new.Count -gt 0) {
                    $ctx = $(if ($s) { "temp $($s.Temp)C, util $($s.UtilGpu)%, power $($s.Power)W, throttle $(Convert-ThrottleBits $s.Throttle)" } else { 'n/a' })
                    $tp = (Get-ThermalSample) -split ','
                    $ctx = $ctx + "; cpu " + $tp[1] + "C/" + $tp[2] + "%/" + $tp[3] + "MHz"
                    Add-Utf8Line -Path $evPath -Line ('            (at that moment: ' + $ctx + ')')
                    [System.IO.File]::WriteAllText($stateF, ('{"lastRecordId":' + $lastId + '}'), (New-Object System.Text.UTF8Encoding($false)))
                }
            }
        } catch {
            Add-Utf8Line -Path $errPath -Line (((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) + '  ' + $_.Exception.Message)
        }
        $i++
        for ($k = 0; $k -lt 5; $k++) { if (Test-Path $stopFlag) { break }; Start-Sleep -Seconds 1 }
    }
    Add-Utf8Line -Path $evPath -Line ('{0}  ---- logger stopped ----' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
}

# ----------------------------------------------------------------------------
# self test (applies the fixes and reverts them, then reports PASS/FAIL)
# ----------------------------------------------------------------------------
function Invoke-SelfTest {
    $sb = New-Object System.Collections.Generic.List[string]
    function T { param([string]$Txt) $sb.Add($Txt); Write-Host $Txt }
    $res = 'UNKNOWN'
    $snap = {
        [pscustomobject]@{
            Aspm      = Get-PowerIndex $PC.PcieSub $PC.PcieAsm
            VideoIdle = Get-PowerIndex $PC.VideoSub $PC.VideoIdle
            UsbSus    = Get-PowerIndex $PC.UsbSub $PC.UsbSus
            Hiberboot = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
            TdrDelay  = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDelay'
            TdrDdi    = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDdiDelay'
            TdrLevel  = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrLevel'
        }
    }
    function Fmt { param($s)
        "aspm(AC/DC)={0}/{1} videoIdleAC={2} usbAC={3} hiberboot={4} tdr={5}/{6}/{7}" -f `
            $(if ($s.Aspm) { $s.Aspm.AC } else { '?' }), $(if ($s.Aspm) { $s.Aspm.DC } else { '?' }),
            $(if ($s.VideoIdle) { $s.VideoIdle.AC } else { '?' }), $(if ($s.UsbSus) { $s.UsbSus.AC } else { '?' }),
            (Show $s.Hiberboot), (Show $s.TdrDelay), (Show $s.TdrDdi), (Show $s.TdrLevel)
    }
    try {
        T ('SELFTEST ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        T ('admin=' + $isAdmin + '  ps=' + $PSVersionTable.PSVersion)
        if (-not $isAdmin) { T 'RESULT: FAIL (needs administrator rights)'; $res = 'FAIL'; return }
        $A = & $snap
        T ('BEFORE : ' + (Fmt $A))
        $fixOk = Invoke-Fix -AssumeYes
        T ('fix returned: ' + $fixOk)
        $B = & $snap
        T ('AFTER  : ' + (Fmt $B))
        $checks = @()
        $checks += @('ASPM off', ($B.Aspm -and $B.Aspm.AC -eq 0 -and $B.Aspm.DC -eq 0))
        $checks += @('display never off', ($B.VideoIdle -and $B.VideoIdle.AC -eq 0))
        $checks += @('USB suspend off', ($B.UsbSus -and $B.UsbSus.AC -eq 0))
        $checks += @('Fast Startup off', ($B.Hiberboot -eq 0))
        $checks += @('TdrDelay=10', ($B.TdrDelay -eq 10))
        $checks += @('TdrDdiDelay=5', ($B.TdrDdi -eq 5))
        for ($i = 0; $i -lt $checks.Count; $i += 2) { T ('CHECK  ' + $(if ($checks[$i + 1]) { 'PASS' } else { 'FAIL' }) + '  ' + $checks[$i]) }
        Invoke-Revert
        $C = & $snap
        T ('REVERTED: ' + (Fmt $C))
        $same = ((Fmt $A) -eq (Fmt $C))
        T ('CHECK  ' + $(if ($same) { 'PASS' } else { 'FAIL' }) + '  revert restores original values')
        # scheduled task permissions
        try {
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Command "exit 0"'
            $trg = New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME)
            Register-ScheduledTask -TaskName 'GPU-Diag-SelfTest' -Action $act -Trigger $trg -Force -ErrorAction Stop | Out-Null
            $ok = $false
            try { $ok = [bool](Get-ScheduledTask -TaskName 'GPU-Diag-SelfTest' -ErrorAction Stop) } catch { $ok = $false }
            T ('CHECK  ' + $(if ($ok) { 'PASS' } else { 'FAIL' }) + '  scheduled-task registration (used by the logger)')
            Unregister-ScheduledTask -TaskName 'GPU-Diag-SelfTest' -Confirm:$false -ErrorAction Stop
            T 'CHECK  PASS  scheduled-task removal'
        } catch {
            T ('CHECK  FAIL  scheduled task -> ' + $_.Exception.Message)
        }
        # event log export
        $ev = Join-Path $env:TEMP ('gpu-diag-selftest-' + $PID + '.evtx')
        try {
            & wevtutil epl System $ev 2>$null | Out-Null
            if (Test-Path $ev) { T ('CHECK  PASS  event log export (' + [math]::Round((Get-Item $ev).Length / 1MB, 1) + ' MB)'); Remove-Item $ev -Force -ErrorAction SilentlyContinue }
            else { T 'CHECK  FAIL  event log export' }
        } catch { T ('CHECK  FAIL  event log export -> ' + $_.Exception.Message) }
        # package creation
        try {
            $tmp = Join-Path $env:TEMP ('gpu-diag-selftest-' + $PID + '.zip')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Compress-Archive -Path (Join-Path $PSScriptRoot '*') -DestinationPath $tmp -Force -ErrorAction Stop
            if (Test-Path $tmp) { T 'CHECK  PASS  zip packaging'; Remove-Item $tmp -Force -ErrorAction SilentlyContinue } else { T 'CHECK  FAIL  zip packaging' }
        } catch { T ('CHECK  FAIL  zip packaging -> ' + $_.Exception.Message) }
        if (-not ($checks -contains $false) -and $same) { $res = 'PASS' } else { $res = 'FAIL' }
    } catch {
        T ('EXCEPTION: ' + $_.Exception.Message)
        T ($_.ScriptStackTrace)
        $res = 'FAIL'
    } finally {
        T ('RESULT: ' + $res)
        try { [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'selftest.log'), ($sb -join "`r`n"), (New-Object System.Text.UTF8Encoding($true))) } catch { }
    }
}

# ----------------------------------------------------------------------------
# one-click mode
# ----------------------------------------------------------------------------
function Invoke-All {
    Say ''
    Say ' ONE-CLICK MODE'
    Say '   1) full report, including driver check  -> ZIP on the Desktop'
    Say '   2) safe fixes (reversible)'
    Say '   3) background logging until it is stopped'
    Say ''
    $a = Read-Host ' Start? (y/n)'
    if ($a -notmatch '^(y|yes)$') { Say ' Cancelled.'; return }

    Say ''
    Say ' STEP 1/3 - report'
    New-DiagPackage | Out-Null

    Say ''
    Say ' STEP 2/3 - safe fixes'
    $fixOk = Invoke-Fix -AssumeYes
    if (-not $fixOk) { Say ' [!] The safe fixes were NOT applied (no admin rights?).' }

    Say ''
    Say ' STEP 3/3 - background logging'
    Invoke-InstallWatch
    $taskOk = $false
    try { $taskOk = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) } catch { $taskOk = $false }

    Say ''
    Say ' ================================================================'
    Say '  DONE. What to do next:'
    Say '   1. restart the PC (the fixes need it)'
    Say '   2. use the PC normally, the logger records in the background'
    Say '   3. when the monitor drops out again, open this tool and choose'
    Say '      "Stop logging + final ZIP", then send that ZIP back.'
    if (-not $taskOk) { Say '  [!] Background logging is NOT registered - run this tool as administrator.' }
    Say ' ================================================================'
    $r = Read-Host ' Restart the PC now? (y/n)'
    if ($r -match '^(y|yes)$') {
        Say ' Restarting in 20 seconds - save your work if needed.'
        shutdown /r /t 20 /c "Restart to apply GPU-Diag settings" | Out-Null
    }
}

# ----------------------------------------------------------------------------
# menu
# ----------------------------------------------------------------------------
function Show-Menu {
    while ($true) {
        try { Clear-Host } catch { }
        Say ' =============================================================='
        Say '  GPU / DISPLAY DIAGNOSTICS'
        Say ("  computer: $env:COMPUTERNAME      admin: $isAdmin")
        Say ' =============================================================='
        Say '  1  DO EVERYTHING  (recommended: report + fixes + logging)'
        Say '  2  Full report only            (read-only, ~1-2 min)'
        Say '  3  Turn ON background logging  (for intermittent problems)'
        Say '  4  Stop logging + build final ZIP to send back'
        Say '  5  Apply safe fixes only'
        Say '  6  Undo safe fixes'
        Say '  0  Exit'
        Say ''
        $c = Read-Host ' Choose 0-6'
        switch ($c) {
            '1' { Invoke-All; Read-Host ' Press Enter' | Out-Null }
            '2' { New-DiagPackage | Out-Null; Read-Host ' Press Enter' | Out-Null }
            '3' { Invoke-InstallWatch; Read-Host ' Press Enter' | Out-Null }
            '4' { Invoke-UninstallWatch; New-DiagPackage | Out-Null; Read-Host ' Press Enter' | Out-Null }
            '5' { Invoke-Fix | Out-Null; Read-Host ' Press Enter' | Out-Null }
            '6' { Invoke-Revert; Read-Host ' Press Enter' | Out-Null }
            '0' { return }
            default { }
        }
    }
}

# ----------------------------------------------------------------------------
# dispatch
# ----------------------------------------------------------------------------
try {
    switch ($Mode) {
        'Menu'           { Show-Menu }
        'Report'         { New-DiagPackage | Out-Null }
        'Fix'            { Invoke-Fix | Out-Null }
        'Revert'         { Invoke-Revert }
        'InstallWatch'   { Invoke-InstallWatch }
        'UninstallWatch' { Invoke-UninstallWatch }
        'Watch'          { Invoke-Watch }
        'Finish'         { Invoke-UninstallWatch; New-DiagPackage | Out-Null }
        'SelfTest'       { Invoke-SelfTest }
    }
} catch {
    Say (' [!] Unexpected error: ' + $_.Exception.Message)
    Say ('     ' + $_.ScriptStackTrace)
}

if (-not $NoPause -and $Mode -ne 'Watch') {
    Say ''
    Read-Host ' Press Enter to close this window' | Out-Null
}
