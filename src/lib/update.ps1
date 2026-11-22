#Requires -Version 7
# update.ps1 - part of T3 Code Enhanced
#
# Installs a T3 Code Enhanced release without any window. local-enhanced-update.cjs runs it
# hidden when you click the Enhanced update button, or by itself when "Install updates
# automatically" is on. You can also run it by hand.
#
#   1. Downloads the release zip and its .sha256 file.
#   2. Stops unless the zip's SHA-256 matches.
#   3. Unpacks it to a temporary folder and runs that release's install.ps1 -Quiet.
#   4. Writes the outcome to -ResultPath as JSON: { ok, version, restart, error }.
#      restart is true when the install changed T3's own files (title bar or backend
#      patches), which load only after T3 Code restarts. Otherwise a window reload is enough.
#
# OPTIONS
#   -ZipUrl / -SumUrl   release assets (the updater passes them)
#   -ZipPath            use a zip on disk instead of downloading (tests)
#   -Latest             look up the newest release yourself (for running by hand)
#   -Version            the version being installed, for the result file
#   -ResultPath         where the JSON result goes
#   -T3Dir / -HomeDir / -InstallDir / -NoTask   passed through to install.ps1 (tests)

param(
    [string]$ZipUrl     = '',
    [string]$SumUrl     = '',
    [string]$ZipPath    = '',
    [switch]$Latest,
    [string]$Version    = '',
    [string]$ResultPath = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced\update-result.json'),
    [string]$T3Dir      = '',
    [string]$HomeDir    = $HOME,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced'),
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path ([IO.Path]::GetTempPath()) ("t3ce-update-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$logPath = Join-Path $InstallDir 'update.log'

function Write-Result([hashtable]$r) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ResultPath) | Out-Null
    $r | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
function Log([string]$text) {
    try { ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt'), $text) | Out-File -LiteralPath $logPath -Append -Encoding utf8 } catch { }
}

try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $headers = @{ 'User-Agent' = 't3-code-enhanced-updater' }

    if ($Latest) {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/DavidHiFi/t3-code-enhanced/releases/latest' -Headers $headers -TimeoutSec 30
        $ZipUrl = ($rel.assets | Where-Object name -match '^T3-Code-Enhanced-v[\d.]+\.zip$' | Select-Object -First 1).browser_download_url
        $SumUrl = ($rel.assets | Where-Object name -match '\.zip\.sha256$' | Select-Object -First 1).browser_download_url
        $Version = "$($rel.tag_name)".TrimStart('v')
        if (-not $ZipUrl -or -not $SumUrl) { throw "release $($rel.tag_name) has no zip or checksum file" }
    }

    if ($ZipPath) {
        $zip = $ZipPath
    } else {
        if (-not $ZipUrl -or -not $SumUrl) { throw 'no download address given' }
        foreach ($u in $ZipUrl, $SumUrl) {
            if ($u -notmatch '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/') { throw "refusing to download from $u" }
        }
        $zip = Join-Path $work 'release.zip'
        Log "downloading $ZipUrl"
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -Headers $headers -TimeoutSec 120
        # GitHub serves the checksum file as raw bytes; turn them into text before reading the hash
        $sumBody = (Invoke-WebRequest -Uri $SumUrl -Headers $headers -TimeoutSec 30).Content
        if ($sumBody -is [byte[]]) { $sumBody = [Text.Encoding]::ASCII.GetString($sumBody) }
        $want = "$sumBody".Trim().Split()[0].ToUpperInvariant()
        $have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($want -notmatch '^[0-9A-F]{64}$') { throw 'the checksum file is unreadable' }
        if ($have -ne $want) { throw "the download is damaged (SHA-256 $have, expected $want); nothing was changed" }
    }

    $src = Join-Path $work 'release'
    Expand-Archive -LiteralPath $zip -DestinationPath $src -Force
    if (-not (Test-Path -LiteralPath (Join-Path $src 'install.ps1'))) { throw 'the release has no install.ps1' }
    Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File
    if (-not $Version -and (Test-Path -LiteralPath (Join-Path $src 'VERSION'))) { $Version = (Get-Content -LiteralPath (Join-Path $src 'VERSION') -Raw).Trim() }

    $iargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $src 'install.ps1'), '-Quiet', '-HomeDir', $HomeDir, '-InstallDir', $InstallDir)
    if ($T3Dir)  { $iargs += @('-T3Dir', $T3Dir) }
    if ($NoTask) { $iargs += '-NoTask' }
    Log "running install.ps1 for $Version"
    $out = & pwsh @iargs *>&1 | Out-String
    $code = $LASTEXITCODE
    Log ($out.Trim())
    if ($code -ne 0) { throw "install.ps1 stopped with exit code $code (details in $logPath)" }
    $restart = $out -match 'main\.cjs rewritten' -or $out -match 'wrote\s*:\s*chunk'
    Write-Result @{ ok = $true; version = $Version; restart = [bool]$restart; error = $null }
    Log "installed $Version (restart needed: $restart)"
    exit 0
}
catch {
    $msg = $_.Exception.Message
    Log "failed: $msg"
    Write-Result @{ ok = $false; version = $Version; restart = $false; error = $msg }
    exit 1
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
