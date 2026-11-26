$ErrorActionPreference = 'Stop'

# Tests dot-source the product in library mode: functions are declared, but
# nothing is dispatched, no prompt waits and no elevated process is started.
$env:GPU_DIAG_LIB = '1'
. (Join-Path $PSScriptRoot '..\src\GPU-Diag.ps1')
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:TestNo = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ("$Expected" -cne "$Actual") {
        if ($Message) { $Message = $Message + ": expected '$Expected', got '$Actual'" }
        else { $Message = "expected '$Expected', got '$Actual'" }
        throw $Message
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:TestNo++
    $label = '{0,2}. {1}' -f $script:TestNo, $Name
    try {
        & $Body
        $script:Passed++
        Write-Host ('  PASS  ' + $label)
    } catch {
        $script:Failed++
        $script:Failures.Add($label + ' :: ' + $_.Exception.Message)
        Write-Host ('  FAIL  ' + $label + ' :: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Reset-Findings {
    param([string[]]$Lines = @())
    $script:Findings = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { $script:Findings.Add($line) }
}

function Get-Advice {
    param([string]$Fix = 'none', [string]$Watch = 'unknown')
    return ((New-RuAdviceText -FixStatus $Fix -WatchStatus $Watch) -join "`n")
}

$adviceCombos = @(
    @{ F = 'applied'; W = 'ok' },
    @{ F = 'applied'; W = 'session' },
    @{ F = 'failed'; W = 'unknown' },
    @{ F = 'none'; W = 'unknown' },
    @{ F = 'none'; W = 'failed' }
)

$srcPath = Join-Path $PSScriptRoot '..\src\GPU-Diag.ps1'
$srcText = [IO.File]::ReadAllText($srcPath)

# One representative line per Get-RuFinding branch. The test below also checks
# that every regex in Get-RuFinding is covered by at least one fixture.
$fixtureText = @'
[HIGH] Driver for 'NVIDIA GeForce RTX 2060' is not digitally signed - that is a real red flag.
[INFO] Several GPU driver packages are still in the driver store (NVIDIA: 2, AMD: 0) - leftovers of previous installs.
[LOW] Windows has a pending reboot (unfinished driver/update installation) - restart before judging the problem.
[MEDIUM] Windows Update offers 1 driver update(s).
[MEDIUM] GPU driver for 'Test GPU' is 300 days old - clean-install the latest driver.
[HIGH] Windows has no real GPU driver installed ('Test GPU') - install the vendor driver.
[INFO] Multiple video adapters detected (2).
[LOW] More than one monitor is connected - a useful test is to run a single monitor only.
[HIGH] Video-related device with an error state: Test GPU [Error] - reinstall the GPU driver.
[LOW] Device Manager shows 1 device(s) with problems.
[HIGH] Heavy GPU process 'test' (50%) runs from a temp folder - possible unwanted software.
[HIGH] Process with a mining-tool name is running: test-tool (pid 123).
[MEDIUM] GPU reports thermal/power throttling right now (SwThermal) - cooling should be checked.
[MEDIUM] GPU temperature is 85 C at idle-ish load - check fans, dust, airflow.
[MEDIUM] PCIe link dropped to gen 1 (max gen 3) - check the slot.
[MEDIUM] CPU is running at 55% of its maximum frequency right now - firmware throttling.
[HIGH] ACPI thermal zone 'TZ01' reports 95 C - cooling is not keeping up.
[HIGH] Windows logged 3 'processor speed limited by firmware' event(s) - the CPU is throttling.
[MEDIUM] PCIe ASPM power saving is enabled - a classic cause of random display drop-outs.
[MEDIUM] Windows turns the display off after 10 min on AC power - rule this out.
[LOW] Fast Startup is ON - it keeps driver state across reboots.
[HIGH] TdrLevel=0 is set: driver timeout recovery is DISABLED.
[INFO] TdrDelay was already raised to 10 s - somebody fought this problem before.
[HIGH] Display driver reset/error events: 3 in 30 days.
[HIGH] WHEA hardware error events: 2.
[HIGH] Kernel-Power 41: 1 unplanned power loss(es).
[HIGH] BSOD / BugCheck events: 2.
[MEDIUM] Kernel-PnP events: 4.
[INFO] No display/power/hardware events in the System log for the last 30 days.
[HIGH] 2 minidump(s) found - the PC has crashed.
[HIGH] Live kernel dump(s) present.
[MEDIUM] Graphics-related application crashes/hangs in the log.
[HIGH] Windows recorded display-engine timeouts (LiveKernelEvent 141/117 = video engine stopped responding).
[MEDIUM] Windows recorded 2 live-kernel/BSOD error report(s).
[MEDIUM] GPU overclocking / overlay software is running.
[MEDIUM] Hardware-accelerated GPU scheduling (HAGS) is enabled and Windows logged display resets.
[MEDIUM] Multi-plane overlay (MPO) is enabled and Windows logged display resets.
[MEDIUM] The newest GPU driver package was installed after the first display error - the driver is the prime suspect.
[LOW] The screen runs at 144 Hz and there were display resets: as a cheap cable/bandwidth test, set 60 Hz for a day.
'@
$findingFixtures = @($fixtureText -split "`r?`n" | Where-Object { $_ })

Test-Case 'findings have a Russian title and an action' {
    $start = $srcText.IndexOf('function Get-RuFinding')
    $end = $srcText.IndexOf('function New-RuAdviceText')
    Assert-True ($start -ge 0 -and $end -gt $start) 'cannot locate Get-RuFinding in the source'
    $body = $srcText.Substring($start, $end - $start)
    $patterns = @([regex]::Matches($body, "-match '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($patterns.Count -ge 35) ('expected at least 35 patterns, got ' + $patterns.Count)

    foreach ($pattern in $patterns) {
        $hit = @($findingFixtures | Where-Object { $_ -match $pattern })
        Assert-True ($hit.Count -gt 0) ('no fixture matches Get-RuFinding pattern: ' + $pattern)
    }

    foreach ($line in $findingFixtures) {
        $ru = Get-RuFinding -Line $line
        Assert-True ($null -ne $ru) ('Get-RuFinding returned null for: ' + $line)
        Assert-True ($ru.T.Trim().Length -gt 0) ('empty Russian title for: ' + $line)
        Assert-True ($ru.S.Trim().Length -gt 0) ('empty step key for: ' + $line)
        $block = @(Get-RuStepText -Key $ru.S)
        Assert-True ($block.Count -gt 0) ("empty step text for key '" + $ru.S + "': " + $line)
    }
}

Test-Case 'unknown finding points to report.txt' {
    Reset-Findings @('[HIGH] Unknown condition XYZZY-42 for the test.')
    $text = Get-Advice
    Assert-True ($text.Contains('Техническая находка (см. report.txt).')) 'fallback title is missing'
    Assert-True ($text.Contains('[HIGH] Unknown condition XYZZY-42 for the test.')) 'raw unknown line is missing'
    Reset-Findings
}

Test-Case 'menu numbers and action references are valid' {
    $start = $srcText.IndexOf('function Show-Menu')
    $end = $srcText.IndexOf('# dispatch', $start)
    Assert-True ($start -ge 0 -and $end -gt $start) 'cannot locate Show-Menu in the source'
    $menuBody = $srcText.Substring($start, $end - $start)
    $menuNums = @([regex]::Matches($menuBody, "Say '  (\d)  ") | ForEach-Object { [int]$_.Groups[1].Value })
    Assert-Equal '1,2,3,4,5,6,0' ($menuNums -join ',') 'menu item numbers'
    Assert-True ($menuBody -match 'Choose 0-6') 'menu prompt does not match the 0-6 range'

    Reset-Findings
    $refs = 0
    foreach ($combo in $adviceCombos) {
        $text = Get-Advice -Fix $combo.F -Watch $combo.W
        foreach ($m in [regex]::Matches($text, 'пункт[а-я]*\s+(\d+)', 'IgnoreCase')) {
            $n = [int]$m.Groups[1].Value
            Assert-True ($menuNums -contains $n) ('advice refers to missing menu item: пункт ' + $n)
            $refs++
        }
        foreach ($m in [regex]::Matches($text, 'нажми\s+(\d)', 'IgnoreCase')) {
            $n = [int]$m.Groups[1].Value
            Assert-True ($menuNums -contains $n) ('advice says "нажми ' + $n + '", but the menu has no such item')
            $refs++
        }
    }
    Assert-True ($refs -gt 0) 'no menu references found in the generated advice'
    Reset-Findings
}

Test-Case 'advice text: empty, one HIGH and duplicate steps' {
    Reset-Findings
    $text = Get-Advice
    Assert-True ($text.Contains('В данных нет явных проблем.')) 'empty report must say there are no obvious problems'
    Assert-True (-not $text.Contains('С этого и стоит начать.')) 'empty report must not tell the owner where to start'
    Assert-True (-not ($text -match '(?m)^  \d+\. ')) 'empty report must not print numbered actions'

    Reset-Findings @('[HIGH] TdrLevel=0 is set: driver timeout recovery is DISABLED.')
    $text = Get-Advice
    Assert-True ($text.Contains('Отключено восстановление после зависания драйвера.')) 'one HIGH: title is missing'
    Assert-True ($text.Contains('С этого и стоит начать.')) 'one HIGH: start hint is missing'
    Assert-True (-not $text.Contains('Важных признаков всего')) 'one HIGH: must not print the multi-HIGH line'
    Assert-True ($text.Contains('Не меняй TdrLevel и TdrDelay вручную:')) 'one HIGH: action block is missing'

    Reset-Findings @(
        '[HIGH] WHEA hardware error events: 2.',
        '[HIGH] Kernel-Power 41: 1 unplanned power loss(es).'
    )
    $text = Get-Advice
    Assert-True ($text.Contains('Важных признаков всего: 2 — остальные ниже, по порядку.')) 'two HIGH: count line is missing'
    $actionCount = ([regex]::Matches($text, [regex]::Escape('Проверь питание:'))).Count
    Assert-Equal 1 $actionCount 'two findings with the same step must print that step once'
    $numbered = ([regex]::Matches($text, '(?m)^  \d+\. ')).Count
    Assert-Equal 1 $numbered 'two findings with the same step must print one numbered block'
    Reset-Findings
}

Test-Case 'Convert-ThrottleBits decodes known masks and passes unknown input through' {
    Assert-Equal '' (Convert-ThrottleBits '') 'empty'
    Assert-Equal 'none' (Convert-ThrottleBits '0') 'zero'
    Assert-Equal 'GpuIdle' (Convert-ThrottleBits '1') 'bit 1'
    Assert-Equal 'SwPowerCap' (Convert-ThrottleBits '4') 'bit 4'
    Assert-Equal 'GpuIdle+SwPowerCap' (Convert-ThrottleBits '5') 'bits 1+4'
    Assert-Equal 'HwSlowdown' (Convert-ThrottleBits ' 8 ') 'whitespace and bit 8'
    Assert-Equal 'DisplayClock' (Convert-ThrottleBits '100') 'bit 256'
    Assert-Equal 'GpuIdle+AppClocks+SwPowerCap+HwSlowdown+SyncBoost+SwThermal+HwThermal+HwPowerBrake+DisplayClock' (Convert-ThrottleBits '1FF') 'all known bits'
    Assert-Equal 'zz' (Convert-ThrottleBits 'zz') 'invalid hex'
}

Test-Case 'Decode-MonName decodes arrays and trims zeros' {
    Assert-Equal '' (Decode-MonName $null) 'null'
    Assert-Equal '' (Decode-MonName @()) 'empty array'
    Assert-Equal '' (Decode-MonName @(0, 0)) 'only zeros'
    Assert-Equal 'ABC' (Decode-MonName @(65, 66, 67, 0)) 'ASCII name'
    Assert-Equal 'A' (Decode-MonName @(32, 65, 32, 0)) 'surrounding spaces'
}

Test-Case 'Convert-OutputTech maps known codes and keeps unknown values' {
    Assert-Equal '' (Convert-OutputTech $null) 'null'
    Assert-Equal 'VGA' (Convert-OutputTech 0) 'VGA'
    Assert-Equal 'HDMI' (Convert-OutputTech 5) 'HDMI'
    Assert-Equal 'DisplayPort (external)' (Convert-OutputTech 10) 'DisplayPort'
    Assert-Equal 'Internal panel' (Convert-OutputTech 2147483648) 'internal panel flag'
    Assert-Equal 'Other (99)' (Convert-OutputTech 99) 'unknown code'
    Assert-Equal 'x' (Convert-OutputTech 'x') 'non-numeric value'
}

Test-Case 'gpu-watch.csv header and row agree in count and order' {
    $header = (Get-WatchCsvHeader).Split(',')
    Assert-Equal 19 $header.Count 'header column count'
    Assert-Equal 'timestamp' $header[0] 'first column'
    Assert-Equal 'monitors' $header[15] 'monitors column'
    Assert-Equal 'active_window' $header[18] 'last column'

    $sample = [pscustomobject]@{
        Name = 'GPU A'; Driver = '1.2.3'; Temp = 55; UtilGpu = 12; UtilMem = 3; MemUsed = 512
        Power = 40; PowerLimit = 120; ClockSm = 1800; ClockMem = 7000; Fan = 35; PState = 'P2'
        Throttle = '4'; PcieGen = '3'; PcieWidth = '16'
    }
    $row = (Format-WatchCsvRow -Stamp '2026-11-27 10:00:00' -Sample $sample -MonCount 2 -Window 'browser').Split(',')
    Assert-Equal 19 $row.Count 'row column count'
    Assert-Equal '2026-11-27 10:00:00' $row[0] 'timestamp order'
    Assert-Equal 'GPU A' $row[1] 'gpu order'
    Assert-Equal '4' $row[13] 'throttle bits order'
    Assert-Equal 'SwPowerCap' $row[14] 'throttle names order'
    Assert-Equal '2' $row[15] 'monitors order'
    Assert-Equal '3' $row[16] 'pcie gen order'
    Assert-Equal '16' $row[17] 'pcie width order'
    Assert-Equal '"browser"' $row[18] 'active window order'

    $emptyRow = (Format-WatchCsvRow -Stamp '2026-11-27 10:00:05' -Sample $null -MonCount 1 -Window '').Split(',')
    Assert-Equal 19 $emptyRow.Count 'row without a sample: column count'
    Assert-Equal '' $emptyRow[1] 'row without a sample: gpu is empty'
    Assert-Equal '1' $emptyRow[15] 'row without a sample: monitors'
    Assert-Equal '""' $emptyRow[18] 'row without a sample: empty window'

    $quoted = Format-WatchCsvRow -Stamp '2026-11-27 10:00:10' -Sample $null -MonCount 0 -Window 'a"b'
    Assert-True ($quoted.EndsWith(',"a''b"')) 'quotes in the window title must not break the CSV'
}

Test-Case 'user texts have no placeholders or empty bullets' {
    Reset-Findings
    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($combo in $adviceCombos) {
        foreach ($line in (New-RuAdviceText -FixStatus $combo.F -WatchStatus $combo.W)) { $texts.Add($line) }
    }
    $keys = @($findingFixtures | ForEach-Object {
        $ru = Get-RuFinding -Line $_
        if ($ru -and $ru.S) { $ru.S }
    } | Select-Object -Unique)
    foreach ($key in $keys) {
        foreach ($line in @(Get-RuStepText -Key $key)) { $texts.Add($line) }
    }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\src\README-RU.txt'))) { $texts.Add($line) }

    $all = $texts -join "`n"
    Assert-True (-not ($all -match '(?i)\bTODO\b')) 'found TODO in user texts'
    Assert-True (-not ($all -match '(?i)\bundefined\b')) 'found "undefined" in user texts'
    Assert-True (-not ($all -match '(?m)^\s*-\s*$')) 'found an empty "  - " bullet in user texts'
    Reset-Findings
}

Test-Case 'harness catches a deliberately false expectation' {
    $caught = $false
    try {
        Assert-Equal 'expected' 'actual' 'deliberate false expectation'
    } catch {
        $caught = $true
    }
    Assert-True $caught 'the harness did not detect the false expectation'
}

Reset-Findings
Write-Host ''
$total = $script:Passed + $script:Failed
Write-Host ("TESTS: {0}/{1} PASS" -f $script:Passed, $total)
if ($script:Failed -gt 0) {
    Write-Host 'Failed:'
    foreach ($failure in $script:Failures) { Write-Host ('  ' + $failure) }
    exit 1
}
exit 0
