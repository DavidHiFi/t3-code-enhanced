#Requires -Version 7
# install.ps1 - T3 Code Enhanced installer
#
# Installs or updates T3 Code Enhanced for the current Windows user. Run it again at
# any time: it is safe to repeat, and it is also how you update to a new release.
#
#   1. Copies the patchers and the guard to %LOCALAPPDATA%\T3CodeEnhanced\lib.
#   2. Copies the add-ons to ~/.t3. Add-on files that already exist are backed up to
#      %LOCALAPPDATA%\T3CodeEnhanced\addon-backups first. Your own local-ui.css is
#      never overwritten.
#   3. Adds any missing settings to ~/.t3/local-patches.json. Settings you changed
#      stay as they are.
#   4. Patches app.asar and server.asar (each patcher backs up the original first).
#   5. Registers the T3CodeEnhanced-Guard scheduled task, which applies the patches
#      again after every T3 Code update.
#
# OPTIONS
#   -Reset       put every add-on and setting back to the release defaults
#                (backed up first; local-ui.css is still kept)
#   -NoTask      skip the scheduled task (patches then stop after the next update)
#   -T3Dir / -HomeDir / -InstallDir   other locations (used by the tests)

param(
    [switch]$Reset,
    [switch]$NoTask,
    [string]$T3Dir      = '',
    [string]$HomeDir    = $HOME,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Step([string]$text) { Write-Host "-> $text" -ForegroundColor Cyan }

if (-not $T3Dir) { $T3Dir = Find-T3Dir }
if (-not $T3Dir) { throw 'T3 Code was not found under %LOCALAPPDATA%\Programs. Install T3 Code first, or pass -T3Dir.' }
Write-Host "T3 Code: $T3Dir"

$t3Home  = Join-Path $HomeDir '.t3'
$libDir  = Join-Path $InstallDir 'lib'
$config  = Join-Path $t3Home 'local-patches.json'
$backups = Join-Path $InstallDir 'backups'
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'

# 1. lib
Step 'Copying the patchers and the guard'
New-Item -ItemType Directory -Force -Path $libDir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'lib\*') -Destination $libDir -Force
Get-ChildItem -LiteralPath $libDir -File | Unblock-File

# 2. add-ons
Step 'Copying the add-ons to ~/.t3'
$addonSrc = Join-Path $PSScriptRoot 'addons'
$files = @(Get-ChildItem -LiteralPath $addonSrc -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($addonSrc, $_.FullName) })
$addonBackup = Join-Path $InstallDir "addon-backups\$stamp"
foreach ($rel in $files) {
    $dst = Join-Path $t3Home $rel
    $src = Join-Path $addonSrc $rel
    if ($rel -eq 'local-patches.json') { continue }                       # merged below
    if ($rel -eq 'local-ui.css' -and (Test-Path -LiteralPath $dst)) { continue }   # yours
    if (Test-Path -LiteralPath $dst) {
        if ((Get-FileHash -LiteralPath $dst).Hash -eq (Get-FileHash -LiteralPath $src).Hash) { continue }
        $bak = Join-Path $addonBackup $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $bak) | Out-Null
        Copy-Item -LiteralPath $dst -Destination $bak -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
# the uninstaller removes exactly these files
$files | Set-Content -LiteralPath (Join-Path $InstallDir 'installed-files.txt') -Encoding utf8
if (Test-Path -LiteralPath $addonBackup) { Write-Host "   replaced add-ons saved in $addonBackup" }

# 3. settings
Step 'Updating ~/.t3/local-patches.json'
$defaults = Get-Content -LiteralPath (Join-Path $addonSrc 'local-patches.json') -Raw | ConvertFrom-Json -AsHashtable
if ((Test-Path -LiteralPath $config) -and -not $Reset) {
    try { $current = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "~/.t3/local-patches.json is not valid JSON ($($_.Exception.Message)). Fix it, or run install.ps1 -Reset." }
    if ($null -eq $current) { $current = @{} }
    $added = @()
    foreach ($key in $defaults.Keys) {
        if (-not $current.ContainsKey($key)) { $current[$key] = $defaults[$key]; $added += $key }
        elseif ($defaults[$key] -is [hashtable] -and $current[$key] -is [hashtable]) {
            foreach ($sub in $defaults[$key].Keys) {
                if (-not $current[$key].ContainsKey($sub)) { $current[$key][$sub] = $defaults[$key][$sub]; $added += "$key.$sub" }
            }
        }
    }
    if ($added) {
        Copy-Item -LiteralPath $config -Destination "$config.$stamp.bak" -Force
        $current | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config -Encoding utf8
        Write-Host "   added: $($added -join ', ')"
    } else { Write-Host '   nothing to add' }
} else {
    if (Test-Path -LiteralPath $config) { Copy-Item -LiteralPath $config -Destination "$config.$stamp.bak" -Force }
    New-Item -ItemType Directory -Force -Path $t3Home | Out-Null
    Copy-Item -LiteralPath (Join-Path $addonSrc 'local-patches.json') -Destination $config -Force
    Write-Host '   wrote the default settings'
}

# 4. patches
$failed = $false
foreach ($p in 'patch-app-asar.ps1', 'patch-server-asar.ps1') {
    Step "Running $p"
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $libDir $p) -Apply -T3Dir $T3Dir -ConfigPath $config -BackupDir $backups *>&1 | Out-String
    $code = $LASTEXITCODE
    $out.Trim().Split("`n") | ForEach-Object { Write-Host "   $($_.TrimEnd())" }
    if ($code -ne 0 -and $code -ne 2) {
        $failed = $true
        Write-Host "   $p stopped with exit code $code. T3 Code is unchanged for that file." -ForegroundColor Yellow
    }
}

# 5. guard task
if (-not $NoTask) {
    Step 'Registering the T3CodeEnhanced-Guard task'
    $taskName = 'T3CodeEnhanced-Guard'
    $vbs = Join-Path $libDir 'guard.vbs'
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    # a running guard keeps its old code in memory; stop it so the new one starts
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($libDir, [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match 'guard\.(ps1|vbs)' } |
        Sort-Object Name -Descending | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)
    $trigger   = [CimInstance[]]@((New-ScheduledTaskTrigger -AtLogOn -User $user),
                 (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 15)))
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                     -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                     -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'T3 Code Enhanced: applies the patches again after T3 Code updates. Remove with uninstall.ps1.' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "   $((Get-ScheduledTask -TaskName $taskName).State)"
}

Write-Host ''
if ($failed) {
    Write-Host 'Installed with warnings (see above). Patches that applied are active after T3 Code restarts.' -ForegroundColor Yellow
    exit 1
}
Write-Host 'Done. Restart T3 Code to load the changes.' -ForegroundColor Green
exit 0
