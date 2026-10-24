# patch-app-asar.ps1 - part of T3 Code Enhanced
#
# Edits T3 Code's app.asar (the Electron main process) in place. The main process
# bundle (apps/desktop/dist-electron/main.cjs) is not minified, so these patches
# anchor on real function names that survive builds.
#
# PATCHES (each edit keeps the exact byte length; asar entries are addressed by
# offset and size, so a length change would corrupt the archive)
#   titlebar   native Windows title bar instead of T3's drawn one. In
#              getWindowTitleBarOptions the non-macOS branch returns titleBarStyle
#              "hidden" plus a titleBarOverlay. The edit makes it return {} and keeps
#              the original object inside a comment. Tapping Alt then shows T3's
#              View/Window/Help menu bar, as in other native Windows apps.
#   localcss   calls ~/.t3/local-main.cjs with the main window on every page load.
#              That hook lives outside the install folder, so updates keep it. It
#              loads the CSS and scripts in ~/.t3 and sets the window backdrop. The
#              edit replaces a development-only navigation check at the start of the
#              main window's did-finish-load handler (environment.isDevelopment is
#              false in the installed app) with a guarded require(), padded with
#              spaces to the same length. A missing or broken hook does nothing.
#
# CONFIG  ~/.t3/local-patches.json. -Apply brings every patch to what it asks for:
#           "nativeTitleBar": true        native frame (false = T3's own)
#           "localUiCss": true            load the add-ons (false = stock)
#           "windowMaterial": "acrylic"   acrylic | mica | tabbed | windhawk | none;
#                                         any but none also installs the hook
#         A missing file or key means false (stock).
#
# MODES (read-only unless -Apply or -Revert)
#   -Status   report each patch and whether it matches the config (default)
#   -Apply    back up, then patch or unpatch each site to match the config
#   -Revert   back up, restore every site to stock regardless of the config
#
# EXIT CODES  0 = done or reported, 1 = error or unknown shape (nothing written),
#             2 = already in the requested state
#
# Takes effect when T3 Code starts. A running instance keeps what it loaded.

param(
    [switch]$Status,
    [switch]$Apply,
    [switch]$Revert,
    [string]$T3Dir      = '',
    [string]$AsarPath   = '',
    [string]$ConfigPath = (Join-Path $HOME '.t3/local-patches.json'),
    [string]$BackupDir  = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced/backups')
)

if ($PSVersionTable.PSVersion.Major -lt 6) { Write-Output 'run with pwsh 7'; exit 1 }
$ErrorActionPreference = 'Stop'
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$nl = [char]10
$tab = [char]9

$mode = if ($Apply -and -not $Revert) { 'Apply' } elseif ($Revert -and -not $Apply) { 'Revert' } else { 'Status' }
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $AsarPath) {
    if (-not $T3Dir) { $T3Dir = Find-T3Dir }
    if (-not $T3Dir) { Write-Output 'refusing: T3 Code install folder not found; pass -T3Dir'; exit 1 }
    $AsarPath = Join-Path $T3Dir 'resources/app.asar'
}
if (-not (Test-Path -LiteralPath $AsarPath)) { Write-Output "refusing: app.asar not found at $AsarPath - investigate"; exit 1 }

# --- config ----------------------------------------------------------------------
$config = [pscustomobject]@{}
if (Test-Path -LiteralPath $ConfigPath) {
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { Write-Output "refusing: $ConfigPath is not valid JSON - fix it first"; exit 1 }
}
function Get-Flag([string]$name) { return [bool]($config.PSObject.Properties[$name] -and $config.$name -eq $true) }

# --- asar header -------------------------------------------------------------------
$sizeBefore = (Get-Item -LiteralPath $AsarPath).Length
$shaBefore  = (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash
$fs = [System.IO.File]::Open($AsarPath, 'Open', 'Read', 'ReadWrite')
try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 4; $pickle = $br.ReadUInt32()
    $fs.Position = 8; $hb = $br.ReadBytes([int]$pickle)
} finally { $fs.Close() }
$jsonLen = [BitConverter]::ToUInt32($hb, 4)
$header = [System.Text.Encoding]::UTF8.GetString($hb, 8, [int]$jsonLen) | ConvertFrom-Json
$dataOffset = 8 + $pickle

function Find-Entry([string]$path) {
    $node = $header
    foreach ($part in $path.Split('/')) {
        if (-not $node.files -or -not $node.files.PSObject.Properties[$part]) { return $null }
        $node = $node.files.$part
    }
    if ($node.PSObject.Properties['unpacked'] -and $node.unpacked) { return $null }
    return [pscustomobject]@{ Path = $path; Offset = [int64]$node.offset; Size = [int64]$node.size }
}

function Read-Entry($entry) {
    $f = [System.IO.File]::Open($AsarPath, 'Open', 'Read', 'ReadWrite')
    try {
        $f.Position = $dataOffset + $entry.Offset
        $b = New-Object byte[] ([int]$entry.Size)
        $null = $f.Read($b, 0, [int]$entry.Size)
        return $Latin1.GetString($b)
    } finally { $f.Close() }
}

$mainEntry = Find-Entry 'apps/desktop/dist-electron/main.cjs'
if (-not $mainEntry) { Write-Output 'refusing: apps/desktop/dist-electron/main.cjs not found (packed) in app.asar - investigate'; exit 1 }
$mainText = Read-Entry $mainEntry

# --- patch: titlebar -----------------------------------------------------------------
function Resolve-TitleBar([string]$text, [string]$want) {
    $fnAt = $text.IndexOf('function getWindowTitleBarOptions(', [System.StringComparison]::Ordinal)
    if ($fnAt -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'getWindowTitleBarOptions not found'; Edits = @() } }
    if ($text.IndexOf('function getWindowTitleBarOptions(', $fnAt + 1, [System.StringComparison]::Ordinal) -ge 0) {
        return @{ State = 'UNKNOWN'; Detail = 'getWindowTitleBarOptions defined twice - ambiguous'; Edits = @() }
    }
    $end = $text.IndexOf($nl + 'function ', $fnAt + 10, [System.StringComparison]::Ordinal)
    if ($end -lt 0 -or ($end - $fnAt) -gt 1500) { return @{ State = 'UNKNOWN'; Detail = 'getWindowTitleBarOptions body not bounded'; Edits = @() } }
    $body = $text.Substring($fnAt, $end - $fnAt)
    $darwin = $body.IndexOf('if (platform === "darwin") return', [System.StringComparison]::Ordinal)
    if ($darwin -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'macOS branch not found (shape changed)'; Edits = @() } }
    $R = '(?<R>\n\t\ttitleBarStyle: "hidden",\n\t\ttitleBarOverlay: \{[^{}]*\})'
    $mS = [regex]::Matches($body, '\treturn \{' + $R + '\n\t\};')
    $mP = [regex]::Matches($body, 'return\{\};/\*' + $R + '\*/')
    if ($mS.Count + $mP.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "non-macOS return matched $($mS.Count) stock / $($mP.Count) patched (expected 1 total)"; Edits = @() } }
    $isPatched = $mP.Count -eq 1
    $m = if ($isPatched) { $mP[0] } else { $mS[0] }
    if ($m.Index -lt $darwin) { return @{ State = 'UNKNOWN'; Detail = 'matched return is not after the macOS branch'; Edits = @() } }
    $r = $m.Groups['R'].Value
    if ($r.Contains('*/')) { return @{ State = 'UNKNOWN'; Detail = 'overlay object contains */ - cannot comment it out'; Edits = @() } }
    $stock   = $tab + 'return {' + $r + $nl + $tab + '};'
    $patched = 'return{};/*' + $r + '*/'
    if ($stock.Length -ne $patched.Length) { return @{ State = 'UNKNOWN'; Detail = 'titlebar edit would change length'; Edits = @() } }
    $state = if ($isPatched) { 'PATCHED' } else { 'ORIGINAL' }
    $edits = @()
    if ($want -eq 'patched' -and -not $isPatched) { $edits = @(@{ Rel = $fnAt + $m.Index; Old = $stock; New = $patched }) }
    if ($want -eq 'stock' -and $isPatched)        { $edits = @(@{ Rel = $fnAt + $m.Index; Old = $patched; New = $stock }) }
    $label = if ($isPatched) { 'native Windows frame' } else { 'T3 drawn title bar (stock)' }
    return @{ State = $state; Detail = $label; Edits = $edits }
}

# --- patch: localcss -----------------------------------------------------------------
function Resolve-LocalCss([string]$text, [string]$want) {
    $stockRe = 'if \(environment\.isDevelopment && !isSameOriginRendererNavigation\(\{\n(?<t>\t+)applicationUrl,\n\k<t>navigationUrl: window\.webContents\.getURL\(\)\n\t+\}\)\) return;(?=\n\t+clearDevelopmentLoadRetry\(\);)'
    $code = 'try{require(require("os").homedir()+"/.t3/local-main.cjs")(window)}catch{}'
    # an early version of the hook injected local-ui.css directly; -Apply upgrades it
    $legacy = 'try{window.webContents.insertCSS(require("fs").readFileSync(require("os").homedir()+"/.t3/local-ui.css","utf8")).catch(()=>{})}catch{}'
    $tail = ' +(?=\n\t+clearDevelopmentLoadRetry\(\);)'
    $mS = [regex]::Matches($text, $stockRe)
    $mP = [regex]::Matches($text, [regex]::Escape($code) + $tail)
    $mL = [regex]::Matches($text, [regex]::Escape($legacy) + $tail)
    if ($mS.Count + $mP.Count + $mL.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "did-finish-load dev check matched $($mS.Count) stock / $($mP.Count) patched / $($mL.Count) legacy (expected 1 total)"; Edits = @() } }
    if ($mL.Count -eq 1) {
        $m = $mL[0]
        $edits = @()
        if ($want -eq 'patched') { $edits = @(@{ Rel = $m.Index; Old = $m.Value; New = $code + (' ' * ($m.Value.Length - $code.Length)) }) }
        if ($want -eq 'stock') { $lineStart = $text.LastIndexOf($nl, $m.Index) + 1; $indent = $text.Substring($lineStart, $m.Index - $lineStart); $inner = $indent + $tab
            $edits = @(@{ Rel = $m.Index; Old = $m.Value; New = 'if (environment.isDevelopment && !isSameOriginRendererNavigation({' + $nl + $inner + 'applicationUrl,' + $nl + $inner + 'navigationUrl: window.webContents.getURL()' + $nl + $indent + '})) return;' }) }
        if ($edits.Count -and $edits[0].New.Length -ne $m.Value.Length) { return @{ State = 'UNKNOWN'; Detail = 'legacy localcss edit would change length'; Edits = @() } }
        return @{ State = 'LEGACY'; Detail = 'old direct local-ui.css load, no local-main.cjs hook'; Edits = $edits }
    }
    $isPatched = $mP.Count -eq 1
    $m = if ($isPatched) { $mP[0] } else { $mS[0] }
    if ($isPatched) {
        # the stock text is fixed apart from its indent, which sits one tab deeper than the line
        $lineStart = $text.LastIndexOf($nl, $m.Index) + 1
        $indent = $text.Substring($lineStart, $m.Index - $lineStart)
        $inner = $indent + $tab
        $stock = 'if (environment.isDevelopment && !isSameOriginRendererNavigation({' + $nl + $inner + 'applicationUrl,' + $nl + $inner + 'navigationUrl: window.webContents.getURL()' + $nl + $indent + '})) return;'
        $patched = $m.Value
    } else {
        $stock = $m.Value
        if ($code.Length -gt $stock.Length) { return @{ State = 'UNKNOWN'; Detail = 'insertCSS call does not fit the dev check'; Edits = @() } }
        $patched = $code + (' ' * ($stock.Length - $code.Length))
    }
    if ($stock.Length -ne $patched.Length) { return @{ State = 'UNKNOWN'; Detail = 'localcss edit would change length'; Edits = @() } }
    $state = if ($isPatched) { 'PATCHED' } else { 'ORIGINAL' }
    $edits = @()
    if ($want -eq 'patched' -and -not $isPatched) { $edits = @(@{ Rel = $m.Index; Old = $stock; New = $patched }) }
    if ($want -eq 'stock' -and $isPatched)        { $edits = @(@{ Rel = $m.Index; Old = $patched; New = $stock }) }
    $label = if ($isPatched) { 'calls ~/.t3/local-main.cjs' } else { 'no local hook (stock)' }
    return @{ State = $state; Detail = $label; Edits = $edits }
}

$script:jsCheck = Get-JsChecker $(if ($T3Dir) { $T3Dir } else { Split-Path (Split-Path $AsarPath) })
function Test-Syntax([string]$Text) {
    if (-not $script:jsCheck) { return 'skipped (no node and no T3 Code binary to check with)' }
    $tmp = Join-Path $env:TEMP ('t3e-app-check-{0}.cjs' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.File]::WriteAllBytes($tmp, $Latin1.GetBytes($Text))
    $r = & $script:jsCheck $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($r.Code -eq 0) { return 'ok' }
    return ('FAILED: ' + $r.Output.Trim())
}

try {
    # each patch: name, config flag, resolver
    $patches = @(
        @{ Name = 'titlebar'; Flag = 'nativeTitleBar'; Fn = 'Resolve-TitleBar' },
        @{ Name = 'localcss'; Flag = 'localUiCss';     Fn = 'Resolve-LocalCss' }
    )
    foreach ($pt in $patches) {
        $hookNeeded = $pt.Name -eq 'localcss' -and $config.PSObject.Properties['windowMaterial'] -and $config.windowMaterial -in 'windhawk', 'acrylic', 'mica', 'tabbed'
        $pt.Want = if ($mode -eq 'Revert') { 'stock' } elseif ((Get-Flag $pt.Flag) -or $hookNeeded) { 'patched' } else { 'stock' }
        $pt.R = & $pt.Fn $mainText $(if ($mode -eq 'Status') { 'none' } else { $pt.Want })
    }

    Write-Output ("asar        : {0}  ({1} bytes, sha256 {2})" -f $AsarPath, $sizeBefore, $shaBefore.Substring(0, 16))
    Write-Output ("config      : {0} ({1})" -f $ConfigPath, (($patches | ForEach-Object { '{0}={1}' -f $_.Flag, $(if (Get-Flag $_.Flag) { 'on' } else { 'off' }) }) -join ', '))
    foreach ($pt in $patches) { Write-Output ("{0,-12}: {1}  ({2})" -f $pt.Name, $pt.R.State, $pt.R.Detail) }

    $unknown = @($patches | Where-Object { $_.R.State -eq 'UNKNOWN' })
    if ($mode -eq 'Status') {
        $inSync = @($patches | Where-Object { -not (($_.R.State -eq 'PATCHED' -and $_.Want -eq 'patched') -or ($_.R.State -eq 'ORIGINAL' -and $_.Want -eq 'stock')) }).Count -eq 0
        Write-Output ("state       : {0}" -f $(if ($unknown.Count) { 'UNKNOWN' } elseif ($inSync) { 'IN-SYNC' } else { 'OUT-OF-SYNC' }))
        exit $(if ($unknown.Count) { 1 } else { 0 })
    }
    # per-patch policy: an unrecognized shape skips that patch only
    foreach ($pt in $unknown) { Write-Output ("note        : skipping {0} (shape not recognized; nothing written for it)" -f $pt.Name) }
    $active = @($patches | Where-Object { $_.R.State -ne 'UNKNOWN' })
    $allEdits = @($active | ForEach-Object { foreach ($e in $_.R.Edits) { $e.Patch = $_.Name; $e } })
    if ($allEdits.Count -eq 0) {
        if ($unknown.Count) { Write-Output 'refusing: nothing resolvable to change; investigate the unknown shape'; exit 1 }
        Write-Output 'Already in the requested state; nothing to do.'; exit 2
    }

    $new = $mainText
    foreach ($e in ($allEdits | Sort-Object { $_.Rel } -Descending)) {
        if ($new.Substring($e.Rel, $e.Old.Length) -cne $e.Old) { throw "refusing: $($e.Patch): expected text not at its offset - investigate" }
        $new = $new.Remove($e.Rel, $e.Old.Length).Insert($e.Rel, $e.New)
        Write-Output ("pending     : {0}: {1} -> {2} at main.cjs offset {3}" -f $e.Patch, ($e.Old -replace '\s+', ' ').Substring(0, 24), ($e.New -replace '\s+', ' ').Substring(0, 24), $e.Rel)
    }
    $syn = Test-Syntax $new
    if ($syn -ne 'ok' -and $syn -notmatch '^skipped') { Write-Output "refusing: node --check failed on the edited main.cjs: $syn"; exit 1 }

    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $bak = Join-Path $BackupDir ('app.asar.pre-{0}-{1}.asar' -f $mode.ToLower(), $shaBefore.Substring(0, 8))
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $AsarPath -Destination $bak
        if ((Get-Item -LiteralPath $bak).Length -ne $sizeBefore) { throw 'ABORT: backup size mismatch; nothing written.' }
    }
    Write-Output ("backup      : {0}" -f $bak)
    Get-ChildItem -LiteralPath $BackupDir -Filter 'app.asar.*.asar' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue

    $oldBytes = $Latin1.GetBytes($mainText)
    $newBytes = $Latin1.GetBytes($new)
    if ($newBytes.Length -ne $mainEntry.Size) { throw 'refusing: main.cjs byte length changed; asar would corrupt' }
    $abs = $dataOffset + $mainEntry.Offset
    $f = [System.IO.File]::Open($AsarPath, 'Open', 'ReadWrite', 'Read')
    try {
        $f.Position = $abs
        $now = New-Object byte[] ([int]$mainEntry.Size)
        $null = $f.Read($now, 0, $now.Length)
        if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$now, [byte[]]$oldBytes)) { throw 'ABORT: main.cjs changed since it was read (compare-and-swap failed); nothing written.' }
        $f.Position = $abs
        $f.Write($newBytes, 0, $newBytes.Length)
        $f.Flush()
    } finally { $f.Close() }

    $after = Read-Entry $mainEntry
    if ($after -cne $new) { throw 'ABORT: post-write verification failed.' }
    if ((Get-Item -LiteralPath $AsarPath).Length -ne $sizeBefore) { throw 'ABORT: file size changed' }
    $shaAfter = (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash
    Write-Output ("syntax      : main.cjs: {0}" -f $syn)
    Write-Output ("Patch complete. main.cjs rewritten, verified by byte-read; size unchanged ({0} bytes); asar sha256 {1}" -f $sizeBefore, $shaAfter)
    foreach ($pt in $active) {
        $r2 = & $pt.Fn $after 'none'
        $want2 = if ($pt.Want -eq 'patched') { 'PATCHED' } else { 'ORIGINAL' }
        Write-Output ("{0,-12}: {1}  ({2})" -f $pt.Name, $r2.State, $r2.Detail)
        if ($r2.State -ne $want2) { Write-Output "refusing: post-write audit says $($pt.Name) is $($r2.State), expected $want2"; exit 1 }
    }
    Write-Output $(if ($unknown.Count) { 'state       : IN-SYNC for resolvable patches (skipped: ' + (($unknown | ForEach-Object Name) -join ', ') + ')' } else { 'state       : IN-SYNC' })
    exit 0
}
catch {
    Write-Output ("ERROR: {0}" -f $_.Exception.Message)
    exit 1
}