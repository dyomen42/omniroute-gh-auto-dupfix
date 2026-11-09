#Requires -Version 5.1
<#
.SYNOPSIS
    Apply or restore the gh/auto streaming-duplication fix for omniroute (v3.8.x).

.DESCRIPTION
    The omniroute runtime executes compiled webpack bundles under
    dist\.build\next\server\chunks, NOT the TypeScript sources under open-sse\.
    The bundled module that converts OpenAI-Responses style ".done" snapshots into
    chat-completion chunks (tracker "responsesTextSnapshots") re-emits the full
    accumulated text whenever the upstream (GitHub Copilot) uses a different,
    random item_id per event — producing 3 extra full-text copies per stream.

    This script injects a guard into the minified reconcile() function in each
    affected chunk: when a part carries no recorded fragments while the tracker
    already holds fragments elsewhere, reconcile() returns "" instead of the
    full snapshot text. Standard identity-matched flows are untouched.

.PARAMETER ChunksDir
    Path to the omniroute compiled chunk directory. Defaults to the standard
    npm-global location detected automatically.

.PARAMETER Restore
    Copy the pristine .bak patches in backups\ back over the live chunks
    (assumes backups\ from this repo sits next to scripts\).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\patch-dupfix.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\patch-dupfix.ps1 -Restore
#>
[CmdletBinding()]
param(
    [string]$ChunksDir,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

if (-not $ChunksDir) {
    $candidates = @(
        (Join-Path $env:APPDATA  'npm\node_modules\omniroute\dist\.build\next\server\chunks'),
        (Join-Path $HOME '.omniroute\local\omniroute\dist\.build\next\server\chunks'),
        (Join-Path (Get-Location) 'dist\.build\next\server\chunks')
    )
    $ChunksDir = ($candidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if (-not $ChunksDir) {
        throw ("Could not auto-detect the omniroute chunks directory. " +
               "Pass -ChunksDir '<omniroute>\dist\.build\next\server\chunks'.")
    }
}
Write-Host "Chunks dir : $ChunksDir"

# Only files that contain the compiled tracker module (its guard signature).
$markerRx = [regex]::new('responsesTextSnapshots\?\?=\{closed:!', 'Compiled')
$patchMarker = '(()=>{for(const g of'

if ($Restore) {
    $backupDir = Join-Path $repoRoot 'backups'
    if (-not (Test-Path $backupDir)) { throw "Backup folder not found: $backupDir" }
    $files = Get-ChildItem $backupDir -File | Where-Object { $_.Name -match '\.bak$' }
    if (-not $files) { throw "No backups found in $backupDir" }
    foreach ($b in $files) {
        $target = Join-Path $ChunksDir $b.Name
        if (-not (Test-Path $target)) { Write-Warning "skip (missing in chunks dir): $($b.Name)"; continue }
        Copy-Item $b $target -Force
        Write-Host "RESTORED $($b.Name)"
    }
    Write-Host "`nDone. Restart omniroute."
    return
}

# anchor: function X(a,b,c){if(c.length<b.length)return"";  ...with <track>.sequence++ shortly after
$pattern = 'function\s+\w+\((\w),(\w),(\w)\)\{if\(\3\.length<\2\.length\)return"";(?=.{0,500}\1\.sequence\+\+\)'
$guard   = 'if(0===$2.length&&(()=>{for(const g of $1.items)for(const h of g.parts.values())if(h.fragments.length>0)return!0;return!1})())return"";'

$backupDir = Join-Path $repoRoot 'backups'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$scanned = 0; $patched = 0; $already = 0
foreach ($f in (Get-ChildItem $ChunksDir -Filter '*.js' -File)) {
    $text = [IO.File]::ReadAllText($f.FullName)
    if (-not $markerRx.IsMatch($text)) { continue }
    $scanned++
    if ($text.Contains($patchMarker)) { $already++; Write-Host "ALREADY  $($f.Name)"; continue }

    $rx = [regex]::new($pattern, 'Compiled,Singleline')
    $ms = $rx.Matches($text)
    if ($ms.Count -eq 0) { Write-Warning "UNRECOGNIZED (markered, but pattern did not match): $($f.Name)"; continue }
    if ($ms.Count -gt 1) { Write-Warning "multiple reconcile matches ($($ms.Count)) — patching first only: $($f.Name)" }

    Copy-Item $f.FullName (Join-Path $backupDir ($f.Name + '.bak')) -Force
    $new = $rx.Replace($text, ('${0}' + $guard), 1)
    [IO.File]::WriteAllText($f.FullName, $new)
    $patched++
    Write-Host "PATCHED  $($f.Name)"
}

Write-Host ""
Write-Host "Scanned $scanned candidate file(s): patched=$patched already=$already"
Write-Host "Restart omniroute to load the patched bundles."
