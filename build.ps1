# build.ps1 — собирает dist\GPU-Diag-for-friend.zip для отправки
[CmdletBinding()]
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }
$src = Join-Path $PSScriptRoot 'src'

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

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('gpudiag-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$folder = Join-Path $stage 'GPU-Diag'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
Copy-Item (Join-Path $src '*') -Destination $folder -Recurse -Force

$version = 'unknown'
$m = Select-String -Path (Join-Path $src 'GPU-Diag.ps1') -Pattern "Version\s*=\s*'([0-9.]+)'" | Select-Object -First 1
if ($m -and $m.Matches.Count -gt 0) { $version = $m.Matches[0].Groups[1].Value }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir 'GPU-Diag-for-friend.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $folder -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

$size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host ("Built v{0}: {1} ({2} KB)" -f $version, $zip, $size) -ForegroundColor Green

Add-Type -AssemblyName System.IO.Compression.FileSystem
$a = [System.IO.Compression.ZipFile]::OpenRead($zip)
Write-Host 'Contents:'
$a.Entries | ForEach-Object { Write-Host ("  " + $_.FullName + "  " + $_.Length + " bytes") }
$a.Dispose()
