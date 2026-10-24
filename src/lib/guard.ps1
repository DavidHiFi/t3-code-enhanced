# guard.ps1 - part of T3 Code Enhanced
#
# Keeps the T3 Code Enhanced patches applied across updates and restarts. A T3 Code
# update replaces app.asar and server.asar with stock files; this puts the patches
# back within seconds.
#
# HOW IT WORKS (event-driven: no timer, no polling)
#   1. At start it audits both patchers and applies any that are out of sync with
#      ~/.t3/local-patches.json.
#   2. It then blocks on a Windows file-change notification for *.asar under the
#      T3 install folder.
#   3. A change wakes it. It waits until the folder has been quiet for SettleMs,
#      then audits and applies again. Its own writes raise new events, so it audits
#      once more; a healthy file produces no writes, and the guard settles.
#   4. A failed apply (an update still writing, a locked file) is retried RetryMs
#      apart, MaxRetries times. It never loops.
#   5. If a patch keeps getting reverted (MaxApplies applies in 10 minutes), writing
#      pauses and one WARN is logged, so a fight with another writer cannot spin.
#   6. MAKING THE PATCH LIVE. An update relaunches T3 about 2 seconds after it
#      replaces the files, before the guard can patch them, so the running app
#      loads stock code. After writing patches while T3 runs, the guard:
#        - restarts T3 once, gracefully, when the running instance is the fresh
#          post-update launch (command line has --updated, under RestartWindowSec
#          old). Nobody has started work in it yet.
#        - otherwise, when only UI code changed, reloads the window by ending its
#          renderer process after one minute without keyboard or mouse input. T3
#          reloads the window within a second; the backend and agent runs keep going.
#        - otherwise (title bar or backend patches) logs that they load at the next
#          T3 start. It never closes a T3 window you are working in.
#   7. A fatal error exits with code 1; guard.vbs starts it again 20 s later.
#
# STARTED BY  the per-user scheduled task T3CodeEnhanced-Guard (install.ps1), through
#             the hidden launcher guard.vbs.
# LOG         %LOCALAPPDATA%\T3CodeEnhanced\guard.log (START, APPLIED, LIVE, WARN, ERROR)
#
# PARAMETERS
#   -T3Dir / -LogPath   paths (tests point these at a copy)
#   -NoLive             never restart T3 or reload its window (tests)
#   -MaxSeconds         0 = run until stopped (the task uses 0)

param(
    [string]$T3Dir      = '',
    [string]$LogPath    = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced\guard.log'),
    [int]$SettleMs      = 1500,
    [int]$RetryMs       = 3000,
    [int]$MaxRetries    = 20,
    [int]$MaxApplies    = 6,
    [int]$RestartWindowSec = 180,
    [switch]$NoLive,
    [int]$MaxSeconds    = 0,
    [string]$MutexName  = 'Local\T3CodeEnhancedGuard'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
$Patchers = @((Join-Path $PSScriptRoot 'patch-server-asar.ps1'), (Join-Path $PSScriptRoot 'patch-app-asar.ps1'))

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
    Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force -ErrorAction SilentlyContinue
}

function Write-GuardLog([string]$tag, [string]$text) {
    $line = '{0} {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt'), $tag, $text.Trim()
    try { $line | Out-File -FilePath $LogPath -Append -Encoding utf8 } catch { }
}

# one guard per logon session (tests pass their own name)
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) {
    Write-GuardLog 'WARN' "another guard holds $MutexName; this instance exits without watching."
    exit 3   # guard.vbs stops relaunching on 3
}

if (-not $T3Dir) { $T3Dir = Find-T3Dir }
if (-not $T3Dir) {
    Write-GuardLog 'ERROR' 'T3 Code install folder not found; is T3 Code installed for this user?'
    $mutex.ReleaseMutex()
    exit 1
}
$exeName = (Get-T3Exe $T3Dir).Name

function Invoke-Patcher([string]$Patcher, [string[]]$extra) {
    return (& pwsh -NoProfile -ExecutionPolicy Bypass -File $Patcher -T3Dir $T3Dir @extra *>&1 | Out-String)
}

$script:lastWarn = ''
function Write-WarnOnce([string]$text) {
    if ($text -ne $script:lastWarn) { Write-GuardLog 'WARN' $text; $script:lastWarn = $text }
}

$script:applyTimes  = @()
$script:suspended   = $false
$script:needRestart = $false   # a main-process or backend patch was written
$script:needReload  = $false   # a UI chunk was written
$script:writtenAt   = $null

# audit every patcher; apply any that are out of sync. Returns $true when all are
# clean. A patcher with one unrecognized shape still applies; it skips that shape.
function Invoke-Reconcile([string]$why) {
    $clean = $true
    foreach ($patcher in $Patchers) {
        $name  = Split-Path $patcher -Leaf
        $audit = Invoke-Patcher $patcher @()
        if ($audit -match 'state\s*:\s*(PATCHED|IN-SYNC)') { continue }
        if ($audit -match 'Exception|not found at') { $clean = $false; continue }  # update still writing or file locked: retried
        $now = Get-Date
        $script:applyTimes = @($script:applyTimes | Where-Object { ($now - $_).TotalMinutes -lt 10 })
        if ($script:applyTimes.Count -ge $MaxApplies) {
            $clean = $false
            if (-not $script:suspended) {
                Write-GuardLog 'WARN' ("{0}: reverted {1} times in 10 minutes; writing paused until it stops. Something else is rewriting the file." -f $name, $script:applyTimes.Count)
            }
            $script:suspended = $true
            continue
        }
        $script:suspended = $false
        $applied = Invoke-Patcher $patcher @('-Apply')
        if ($applied -match 'Patch complete') {
            $script:applyTimes += $now
            $script:writtenAt = Get-Date
            if ($applied -match 'main\.cjs rewritten' -or $applied -match 'wrote\s*:\s*chunk \S+\.mjs') { $script:needRestart = $true }
            if ($applied -match 'wrote\s*:\s*chunk \S+\.js ') { $script:needReload = $true }
            Write-GuardLog 'APPLIED' ("{0} ({1}):`n{2}" -f $name, $why, $applied.Trim())
            if ($applied -match 'skipped\s*:') { $clean = $false; Write-WarnOnce ("{0}: unknown shape left unpatched ({1})" -f $name, $why) }
        }
        elseif ($applied -match 'Already in the requested state') { continue }  # a race applied it first
        elseif ($applied -match 'nothing to apply') {
            # every resolvable patch is in place; the rest is an upstream change the
            # patcher refused to guess at
            $clean = $false
            Write-WarnOnce ("{0}: unknown shape ({1})`n{2}" -f $name, $why, $audit.Trim())
        }
        elseif ($applied -match 'ABORT|Exception|not found at') { $clean = $false }  # moved under us: retried
        else {
            $clean = $false
            Write-WarnOnce ("{0}: apply refused ({1})`n{2}" -f $name, $why, $applied.Trim())
        }
    }
    return $clean
}

# --- making written patches live ---------------------------------------------------
function Get-T3Main {
    $procs = @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $exeName) -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($T3Dir, [System.StringComparison]::OrdinalIgnoreCase) })
    $ids = $procs | ForEach-Object { $_.ProcessId }
    return @($procs | Where-Object { $ids -notcontains $_.ParentProcessId -and $_.CommandLine -notmatch '--type=' })
}

function Restart-T3([object]$main) {
    $exe = $main.ExecutablePath
    Write-GuardLog 'LIVE' ("restarting the fresh post-update T3 (pid {0}) so the patches written at {1} load" -f $main.ProcessId, $script:writtenAt.ToString('h:mm:ss tt'))
    try { $null = (Get-Process -Id $main.ProcessId -ErrorAction Stop).CloseMainWindow() } catch { }
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue) {
        & taskkill /PID $main.ProcessId 2>&1 | Out-Null    # graceful (WM_CLOSE to every window), never /F
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    }
    if (Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue) {
        Write-GuardLog 'WARN' 'T3 did not close within 65 s; left running, patches load at its next start'
        return
    }
    Start-Sleep -Seconds 2
    if (@(Get-T3Main).Count -eq 0) { Start-Process -FilePath $exe }
    Write-GuardLog 'LIVE' 'T3 restarted with the patched files'
}

Add-Type -Namespace T3Enhanced -Name Idle -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
public static double Seconds() {
    var li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
    if (!GetLastInputInfo(ref li)) return -1;
    return unchecked((uint)Environment.TickCount - li.dwTime) / 1000.0;
}
'@

function Restart-T3Ui([object]$main) {
    # never reload under someone who is typing: wait for 60 s without keyboard or
    # mouse input (checked every 10 s, up to 10 minutes)
    $deadline = (Get-Date).AddMinutes(10)
    while ([T3Enhanced.Idle]::Seconds() -lt 60) {
        if ((Get-Date) -gt $deadline) { Write-GuardLog 'LIVE' 'window reload skipped: no idle minute in 10 minutes; UI patches load at the next reload (Ctrl+R) or T3 start'; return }
        Start-Sleep -Seconds 10
    }
    # the main window renderer: a renderer child of the main process that is not a
    # <webview> guest (guests carry --enable-blink-features), largest working set
    $r = Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $exeName) -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $main.ProcessId -and $_.CommandLine -match '--type=renderer' -and $_.CommandLine -notmatch '--enable-blink-features' } |
        Sort-Object WorkingSetSize -Descending | Select-Object -First 1
    if (-not $r -or $r.CreationDate -gt $script:writtenAt) { return }   # none, or it already loaded after the write
    Write-GuardLog 'LIVE' ("reloading the T3 window (renderer pid {0}) so the UI patches load; backend and agents untouched" -f $r.ProcessId)
    Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue
}

function Invoke-MakeLive {
    if (-not ($script:needRestart -or $script:needReload)) { return }
    $restart = $script:needRestart; $reload = $script:needReload
    $script:needRestart = $false; $script:needReload = $false
    if ($NoLive) { Write-GuardLog 'LIVE' ("skipped (-NoLive): restart={0} reload={1}" -f $restart, $reload); return }
    $main = @(Get-T3Main) | Select-Object -First 1
    if (-not $main -or $main.CreationDate -gt $script:writtenAt) { return }   # not running, or started after the write
    $age = ((Get-Date) - $main.CreationDate).TotalSeconds
    if ($main.CommandLine -match '--updated' -and $age -lt $RestartWindowSec) { Restart-T3 $main; return }
    if ($restart) { Write-GuardLog 'LIVE' 'title bar or backend patches written while T3 runs; they load at the next T3 start' }
    if ($reload) { Restart-T3Ui $main }
}

# the watcher is created before the first audit, so a change during the audit is not missed
try {
    $watcher = New-Object System.IO.FileSystemWatcher $T3Dir, '*.asar'
}
catch {
    Write-GuardLog 'ERROR' ("cannot watch {0}: {1}" -f $T3Dir, $_.Exception.Message)
    $mutex.ReleaseMutex()
    exit 1
}
$watcher.IncludeSubdirectories = $true
$watcher.InternalBufferSize    = 65536
$watcher.EnableRaisingEvents   = $true

Write-GuardLog 'START' ("watching {0} for *.asar changes{1}" -f $T3Dir, $(if ($NoLive) { ' (-NoLive)' } else { '' }))
$begin = Get-Date

try {
    $clean = Invoke-Reconcile 'start'
    Invoke-MakeLive
    $retriesLeft = if ($clean) { 0 } else { $MaxRetries }

    while ($true) {
        $waitMs = -1                                   # no timeout: block until a file changes
        if ($retriesLeft -gt 0) { $waitMs = $RetryMs }
        if ($MaxSeconds -gt 0) {
            $leftMs = [int](($MaxSeconds - ((Get-Date) - $begin).TotalSeconds) * 1000)
            if ($leftMs -le 0) { break }
            if ($waitMs -lt 0 -or $leftMs -lt $waitMs) { $waitMs = $leftMs }
        }

        $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, $waitMs)
        if ($change.TimedOut -and $retriesLeft -le 0) { continue }
        if ($change.TimedOut) {
            # bounded retry of a failed apply: one attempt per RetryMs, never a loop
            $clean = Invoke-Reconcile 'retry'
            Invoke-MakeLive
            if ($clean) { $retriesLeft = 0 }
            else {
                $retriesLeft--
                if ($retriesLeft -eq 0) { Write-WarnOnce ("gave up after {0} retries; the next change to an asar file will try again" -f $MaxRetries) }
            }
            continue
        }

        # debounce: wait until the folder has been quiet for SettleMs
        do { $quiet = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, $SettleMs) } while (-not $quiet.TimedOut)

        $clean = Invoke-Reconcile ("{0} {1}" -f $change.ChangeType, $change.Name)
        Invoke-MakeLive
        $retriesLeft = if ($clean) { 0 } else { $MaxRetries }
    }
}
catch {
    Write-GuardLog 'ERROR' $_.Exception.Message
    $watcher.Dispose()
    $mutex.ReleaseMutex()
    exit 1
}

$watcher.Dispose()
$mutex.ReleaseMutex()
exit 0
