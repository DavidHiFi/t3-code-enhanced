# common.ps1 - part of T3 Code Enhanced
#
# Shared helpers, dot-sourced by the patchers, the guard and the installer.

# The T3 Code install folder: the first per-user Programs folder that holds a
# "T3 Code*.exe" next to resources\app.asar. Nightly and Beta builds both install
# to %LOCALAPPDATA%\Programs\t3code by default.
function Find-T3Dir {
    $root = Join-Path $env:LOCALAPPDATA 'Programs'
    $candidates = @(Join-Path $root 't3code')
    if (Test-Path -LiteralPath $root) {
        $candidates += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }
    foreach ($dir in $candidates) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'resources\app.asar'))) { continue }
        if (Get-T3Exe $dir) { return $dir }
    }
    return $null
}

# The app's main executable in an install folder ("T3 Code (Nightly).exe",
# "T3 Code (Beta).exe", "T3 Code.exe"), never the uninstaller.
function Get-T3Exe([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    return Get-ChildItem -LiteralPath $Dir -Filter 'T3 Code*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'Uninstall*' } | Select-Object -First 1
}

# A JavaScript runtime for syntax checks: node on PATH, or else T3 Code's own
# Electron binary run as plain Node (ELECTRON_RUN_AS_NODE=1). Returns a script
# block that takes a file path and returns @{ Code; Output }.
function Get-JsChecker([string]$T3Dir) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $exe = $node.Source
        return { param($file) $o = & $exe --check $file 2>&1 | Out-String; @{ Code = $LASTEXITCODE; Output = $o } }.GetNewClosure()
    }
    $t3 = Get-T3Exe $T3Dir
    if ($t3) {
        $exe = $t3.FullName
        return {
            param($file)
            $old = $env:ELECTRON_RUN_AS_NODE
            $env:ELECTRON_RUN_AS_NODE = '1'
            try { $o = & $exe --check $file 2>&1 | Out-String; @{ Code = $LASTEXITCODE; Output = $o } }
            finally { $env:ELECTRON_RUN_AS_NODE = $old }
        }.GetNewClosure()
    }
    return $null
}
