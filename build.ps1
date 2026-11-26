# build.ps1 - builds dist\GPU-Diag.zip for distribution
[CmdletBinding()]
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }
$src = Join-Path $PSScriptRoot 'src'

# Локальное время релизного коммита 1.5.5: 2026-11-27 00:42:00 +03:00.
# Every archive entry gets this timestamp, so repeat builds of the same three
# sources produce the same bytes regardless of checkout mtimes. ZIP keeps no
# time zone and stores 2-second granularity; the stamp is written as-is.
$EntryStamp = [DateTimeOffset]::Parse('2026-11-27T00:42:00+03:00', [Globalization.CultureInfo]::InvariantCulture)

$required = 'GPU-Diag.ps1', 'START-HERE.bat', 'README-RU.txt'
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $src $f))) { throw "Missing source file: src\$f" }
}

# syntax check before packaging
$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'GPU-Diag.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ("  syntax error line " + $_.Extent.StartLineNumber + ": " + $_.Message) -ForegroundColor Red }
    throw "GPU-Diag.ps1 has $($errors.Count) syntax error(s) - archive not built"
}

$version = 'unknown'
$m = Select-String -Path (Join-Path $src 'GPU-Diag.ps1') -Pattern "Version\s*=\s*'([0-9.]+)'" | Select-Object -First 1
if ($m -and $m.Matches.Count -gt 0) { $version = $m.Matches[0].Groups[1].Value }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir 'GPU-Diag.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }

# Deterministic archive: all three entries get the same timestamp, the date of
# the release commit (see $EntryStamp at the top).
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fileStream = [IO.File]::Open($zip, [IO.FileMode]::Create)
try {
    $archive = [System.IO.Compression.ZipArchive]::new($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in ($required | Sort-Object)) {
            $entry = $archive.CreateEntry(('GPU-Diag\' + $f), [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $EntryStamp
            $inStream = [IO.File]::OpenRead((Join-Path $src $f))
            try {
                $outStream = $entry.Open()
                try { $inStream.CopyTo($outStream) } finally { $outStream.Dispose() }
            } finally {
                $inStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $fileStream.Dispose()
}

$size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host ("Built v{0}: {1} ({2} KB)" -f $version, $zip, $size) -ForegroundColor Green

$a = [System.IO.Compression.ZipFile]::OpenRead($zip)
Write-Host 'Contents:'
$a.Entries | ForEach-Object { Write-Host ("  " + $_.FullName + "  " + $_.Length + " bytes") }
$a.Dispose()
