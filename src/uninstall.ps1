#Requires -Version 7
# uninstall.ps1 - removes T3 Code Enhanced
#
#   1. Stops the guard and removes the T3CodeEnhanced-Guard task.
#   2. Puts app.asar and server.asar back to stock.
#   3. Removes the add-on files the installer copied to ~/.t3. Your local-ui.css,
#      your local-patches.json and anything else in ~/.t3 stay.
#   4. Deletes %LOCALAPPDATA%\T3CodeEnhanced (lib, logs, backups).
#
# Restart T3 Code afterwards. A T3 Code update also restores the stock files.

param(
    [switch]$KeepFiles,      # keep %LOCALAPPDATA%\T3CodeEnhanced (backups, logs)
    [string]$T3Dir      = '',
    [string]$HomeDir    = $HOME,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced')
)

$ErrorActionPreference = 'Stop'
$libDir = Join-Path $InstallDir 'lib'
$lib = if (Test-Path -LiteralPath (Join-Path $libDir 'common.ps1')) { $libDir } else { Join-Path $PSScriptRoot 'lib' }
. (Join-Path $lib 'common.ps1')
function Step([string]$text) { Write-Host "-> $text" -ForegroundColor Cyan }

# 1. guard
Step 'Removing the guard task'
$taskName = 'T3CodeEnhanced-Guard'
Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($libDir, [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match 'guard\.(ps1|vbs)' } |
    Sort-Object Name -Descending | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# 2. stock asar files
if (-not $T3Dir) { $T3Dir = Find-T3Dir }
$failed = $false
if ($T3Dir) {
    foreach ($p in 'patch-app-asar.ps1', 'patch-server-asar.ps1') {
        Step "Restoring stock code ($p -Revert)"
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $lib $p) -Revert -T3Dir $T3Dir -BackupDir (Join-Path $env:TEMP 'T3CodeEnhanced-uninstall') *>&1 | Out-String
        $code = $LASTEXITCODE
        $out.Trim().Split("`n") | ForEach-Object { Write-Host "   $($_.TrimEnd())" }
        if ($code -ne 0 -and $code -ne 2) { $failed = $true }
    }
} else { Write-Host '   T3 Code not found; nothing to restore' }

# 3. add-ons
Step 'Removing the add-ons from ~/.t3'
$t3Home = Join-Path $HomeDir '.t3'
$list = Join-Path $InstallDir 'installed-files.txt'
if (Test-Path -LiteralPath $list) {
    foreach ($rel in Get-Content -LiteralPath $list) {
        if (-not $rel -or $rel -in 'local-ui.css', 'local-patches.json') { continue }
        Remove-Item -LiteralPath (Join-Path $t3Home $rel) -Force -ErrorAction SilentlyContinue
    }
    $d = Join-Path $t3Home 'local-ui.d'
    if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d }
} else { Write-Host '   no install record found; ~/.t3 left as it is' }

# 4. files
if (-not $KeepFiles) {
    Step "Deleting $InstallDir"
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) { Write-Host 'Removed, but a stock restore reported a problem (see above). Updating or reinstalling T3 Code also restores stock files.' -ForegroundColor Yellow; exit 1 }
Write-Host 'Removed. Restart T3 Code.' -ForegroundColor Green
exit 0
