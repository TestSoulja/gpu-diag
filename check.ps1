#Requires -Version 5.1
<#
  check.ps1 - repository guard for GPU Diag.

  No dependencies, no network access, no administrator rights.
  Prints one summary line: "CHECK: N/N PASS" and returns 0 when every check
  passes, 1 otherwise. Details are printed above the summary line.

  Checks:
    1. the version is declared in exactly one file under src/ (GPU-Diag.ps1)
    2. CHANGELOG.md has a section for that version
    3. src/ has no http(s) URLs, e-mail addresses, C:\Users\ paths, owner login
    4. src/*.ps1 and src/*.txt have a UTF-8 BOM; .ps1/.bat/.txt are CRLF, .md are LF
    5. build.ps1 produces a ZIP with exactly three files, and GPU-Diag.ps1 inside
       the archive is byte-identical to src/GPU-Diag.ps1
    6. if tag v<version> exists, it is annotated and points at HEAD
    7. README.md and README.en.md do not carry the version
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$srcDir  = Join-Path $root 'src'
$mainPs1 = Join-Path $srcDir 'GPU-Diag.ps1'
$total   = 0
$passed  = 0

function Report-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $script:total++
    if ($Ok) {
        $script:passed++
        Write-Host ("  PASS  {0}  {1}" -f $Name, $Detail)
    } else {
        Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

Write-Host ("GPU Diag guard: {0}" -f $root)

# The mirror keeps only the published state; all work happens in the staging copy.
if ($root.TrimEnd('\') -ieq 'C:\VS\gpu-diag') {
    Write-Host '  ВНИМАНИЕ: это зеркало C:\VS\gpu-diag — работай в стейдже C:\VS\gpu-diag-staging' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 1. version
$version = ''
$versionFiles = @()
if (Test-Path $mainPs1) {
    $m = [regex]::Match([IO.File]::ReadAllText($mainPs1), "Version\s*=\s*'([0-9]+\.[0-9]+(?:\.[0-9]+)?)'")
    if ($m.Success) { $version = $m.Groups[1].Value }
}

if (-not $version) {
    Report-Check '1 version' $false 'cannot read $script:Version from src/GPU-Diag.ps1'
} else {
    foreach ($f in @(Get-ChildItem $srcDir -File -Recurse)) {
        if ([IO.File]::ReadAllText($f.FullName).Contains($version)) { $versionFiles += $f.Name }
    }
    $ok1 = ($versionFiles.Count -eq 1 -and $versionFiles[0] -eq 'GPU-Diag.ps1')
    Report-Check '1 version' $ok1 ("{0}: declared in {1} src file(s): {2}" -f `
        $version, $versionFiles.Count, ($versionFiles -join ', '))
}

if (-not $version) {
    Write-Host ''
    Write-Host ("CHECK: {0}/{1} PASS" -f $passed, $total)
    exit 1
}

# --------------------------------------------------------------- 2. changelog
$changelog = Join-Path $root 'CHANGELOG.md'
$ok2 = $false
$detail2 = 'CHANGELOG.md not found'
if (Test-Path $changelog) {
    $ok2 = [IO.File]::ReadAllText($changelog) -match ("(?m)^##\s+\[" + [regex]::Escape($version) + "\]")
    $detail2 = if ($ok2) { "CHANGELOG.md has section [$version]" }
               else { "CHANGELOG.md has no section [$version]" }
}
Report-Check '2 changelog' $ok2 $detail2

# ------------------------------------------------------------- 3. src hygiene
$patterns = [ordered]@{
    'URL'       = 'https?://'
    'e-mail'    = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'user path' = 'C:\\Users\\'
    'owner login' = 'TestSoulja'
}
$hits = @()
foreach ($f in @(Get-ChildItem $srcDir -File -Recurse)) {
    $lines = [IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($key in $patterns.Keys) {
            if ($lines[$i] -match $patterns[$key]) {
                $hits += ("{0}:{1} {2}" -f $f.Name, ($i + 1), $key)
            }
        }
    }
}
$ok3 = ($hits.Count -eq 0)
$detail3 = if ($ok3) { 'no URLs, e-mails, C:\Users\ paths or owner login in src' }
           else { 'found: ' + (($hits | Select-Object -First 5) -join '; ') }
Report-Check '3 src hygiene' $ok3 $detail3

# ------------------------------------------------------------- 4. BOM and EOL
$bomFail = @()
foreach ($f in @(Get-ChildItem $srcDir -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.txt' })) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (-not $hasBom) { $bomFail += ("{0} (no BOM)" -f $f.Name) }
}

$eolFail = @()
try {
    $eolLines = @(& git -C $root ls-files --eol 2>$null)
    if ($LASTEXITCODE -ne 0) { $eolFail += 'git ls-files --eol failed' }
    foreach ($line in $eolLines) {
        if ($line -notmatch '^i/(\S+)\s+w/(\S+)\s+attr/') { continue }
        $w = $Matches[2]
        $tab = $line.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $filePath = $line.Substring($tab + 1).Trim()
        $ext = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
        if ($ext -eq '.md') {
            if ($w -ne 'lf') { $eolFail += ("{0} (w/{1}, expected LF)" -f $filePath, $w) }
        } elseif ($ext -eq '.ps1' -or $ext -eq '.bat' -or $ext -eq '.txt') {
            if ($w -ne 'crlf') { $eolFail += ("{0} (w/{1}, expected CRLF)" -f $filePath, $w) }
        }
    }
} catch {
    $eolFail += ('git ls-files --eol could not run: ' + $_.Exception.Message)
}
$ok4 = ($bomFail.Count -eq 0 -and $eolFail.Count -eq 0)
$detail4 = if ($ok4) { 'BOM on src *.ps1/*.txt; CRLF for .ps1/.bat/.txt, LF for .md' }
           else { (@($bomFail) + @($eolFail) | Select-Object -First 5) -join '; ' }
Report-Check '4 encodings' $ok4 $detail4

# ---------------------------------------------------------------- 5. archive
$ok5 = $false
$detail5 = ''
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('gpudiag-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $build = Join-Path $root 'build.ps1'
    $null = & $build -OutDir $tmp *> $null
    if (-not $?) { throw 'build.ps1 reported a failure' }
    $zip = Join-Path $tmp 'GPU-Diag.zip'
    if (-not (Test-Path $zip)) { throw 'build.ps1 did not produce GPU-Diag.zip' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names = @($za.Entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
        $expected = @('GPU-Diag/GPU-Diag.ps1', 'GPU-Diag/README-RU.txt', 'GPU-Diag/START-HERE.bat') | Sort-Object
        if ($za.Entries.Count -ne 3) { throw ("archive has {0} entries, expected 3" -f $za.Entries.Count) }
        if (($names -join '|') -ne ($expected -join '|')) {
            throw ('unexpected archive contents: ' + ($names -join ', '))
        }

        $entry = $za.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'GPU-Diag/GPU-Diag.ps1' }
        $shaA = [Security.Cryptography.SHA256]::Create()
        try {
            $stream = $entry.Open()
            try { $hashA = $shaA.ComputeHash($stream) } finally { $stream.Dispose() }
        } finally { $shaA.Dispose() }
        $shaB = [Security.Cryptography.SHA256]::Create()
        try { $hashB = $shaB.ComputeHash([IO.File]::ReadAllBytes($mainPs1)) } finally { $shaB.Dispose() }

        $hexA = ([BitConverter]::ToString($hashA)).Replace('-', '').ToLowerInvariant()
        $hexB = ([BitConverter]::ToString($hashB)).Replace('-', '').ToLowerInvariant()
        if ($hexA -ne $hexB) {
            throw ("GPU-Diag.ps1 in the archive differs from src (archive {0}, src {1})" -f $hexA, $hexB)
        }
        $ok5 = $true
        $zipHash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
        $detail5 = ("3 files, zip {0} bytes, sha256 {1}" -f (Get-Item $zip).Length, $zipHash)
    } finally {
        $za.Dispose()
    }
} catch {
    $ok5 = $false
    $detail5 = $_.Exception.Message
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Report-Check '5 archive' $ok5 $detail5

# -------------------------------------------------------------------- 6. tag
$tag = "v$version"
$ok6 = $true
$detail6 = "tag $tag does not exist yet (not a failure)"
try {
    $null = & git -C $root rev-parse -q --verify ("refs/tags/" + $tag) 2>$null
    if ($LASTEXITCODE -eq 0) {
        $type   = (& git -C $root cat-file -t ("refs/tags/" + $tag)).Trim()
        $head   = (& git -C $root rev-parse HEAD).Trim()
        $target = (& git -C $root rev-list -n 1 ("refs/tags/" + $tag)).Trim()
        if ($type -ne 'tag') {
            $ok6 = $false
            $detail6 = ("tag {0} is not annotated (object type: {1})" -f $tag, $type)
        } elseif ($target -eq $head) {
            $detail6 = ("tag {0} is annotated and points at HEAD ({1})" -f $tag, $head.Substring(0, 7))
        } else {
            # Docs commits after a release move HEAD; that is allowed while src/
            # is still exactly the tagged (released) source.
            $ancestor = $false
            $srcSame = $false
            $null = & git -C $root merge-base --is-ancestor $target $head 2>$null
            if ($LASTEXITCODE -eq 0) {
                $ancestor = $true
                $null = & git -C $root diff --quiet $target $head -- src 2>$null
                $srcSame = ($LASTEXITCODE -eq 0)
            }
            if ($ancestor -and $srcSame) {
                $detail6 = ("tag {0} is annotated; src/ identical to HEAD, docs commits since {1}" -f `
                    $tag, $target.Substring(0, 7))
            } elseif (-not $ancestor) {
                $ok6 = $false
                $detail6 = ("tag {0} ({1}) is not an ancestor of HEAD ({2})" -f $tag, $target.Substring(0, 7), $head.Substring(0, 7))
            } else {
                $ok6 = $false
                $detail6 = ("tag {0} points at {1} and src/ differs from HEAD - the version was not raised" -f `
                    $tag, $target.Substring(0, 7))
            }
        }
    }
} catch {
    $ok6 = $false
    $detail6 = 'git tag check could not run: ' + $_.Exception.Message
}
Report-Check '6 tag' $ok6 $detail6

# ---------------------------------------------------------------- 7. readmes
$readmeFail = @()
foreach ($name in @('README.md', 'README.en.md')) {
    $p = Join-Path $root $name
    if (-not (Test-Path $p)) { $readmeFail += ("{0} (missing)" -f $name); continue }
    if ([IO.File]::ReadAllText($p).Contains($version)) { $readmeFail += ("{0} (contains {1})" -f $name, $version) }
}
$ok7 = ($readmeFail.Count -eq 0)
$detail7 = if ($ok7) { 'README.md and README.en.md carry no version' }
           else { ($readmeFail -join '; ') }
Report-Check '7 readmes' $ok7 $detail7

# ------------------------------------------------------------------ summary
Write-Host ''
Write-Host ("CHECK: {0}/{1} PASS" -f $passed, $total)
if ($passed -eq $total) { exit 0 } else { exit 1 }
