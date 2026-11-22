# patch-server-asar.ps1 - part of T3 Code Enhanced
#
# Edits T3 Code's server.asar (the web UI bundle and the backend) in place. Every
# patch is found by the shape of the code around it, not by fixed offsets or
# minified names, so it keeps working across most nightly builds. When a build
# changes a shape, that one patch is skipped with a log line and the others still
# apply. Nothing is ever written blind.
#
# PATCHES (every edit keeps the exact byte length; asar entries are addressed by
# offset and size, so a length change would corrupt the archive)
#   slowrpc       the "request is slow" toast waits 60 s instead of 15 s
#                 (apps/web/src/rpc/requestLatencyState.ts)
#   opencode      OpenCode cold-start budgets 5 s / 5 s / 4 s -> 9 s. Off by
#                 default; turn it on in local-patches.json if OpenCode times out
#                 at start (packages/provider-opencode)
#   noterm-v3     running a project script never forces the terminal panel open
#                 (apps/web/src/components/chat/useChatTerminalActions.ts)
#   noterm-open   the script-run "open" flag is final, so open:false keeps a newly
#                 created terminal closed (useThreadActions)
#   nofloat       hiding the right panel never pops the open preview or device out
#                 into the floating mini-player
#                 (apps/web/src/components/chat/useRightPanelActions.ts)
#   galaxy        the galaxy artwork in the sidebar header stays with a custom theme,
#                 with the Nightly label on top (apps/web/src/hooks/useSettings.ts
#                 and the sidebar header)
#   scriptbuttons every project script gets its own button instead of one button
#                 and a drop-down (apps/web/src/components/ProjectScriptsControl.tsx)
#   browserdark   built-in browser pages default to dark
#                 (apps/web/src/browser/browserDefaults.ts)
#
# CONFIG  ~/.t3/local-patches.json, key "serverPatches": { "<name>": true|false }.
#         A missing key means the default above (all on except opencode).
#         -Apply brings every patch to what the config asks for, so turning one
#         off and running -Apply reverts just that one.
#
# MODES (read-only unless -Apply or -Revert)
#   -Status   report each patch's state, change nothing (default)
#   -Apply    back up, then patch or unpatch each site to match the config
#   -Revert   back up, restore every patch to stock regardless of the config
#
# EXIT CODES  0 = done or reported, 1 = error (nothing written for the failed
#             part), 2 = already in the requested state
#
# Takes effect when T3 Code restarts. A running instance keeps what it loaded.

param(
    [switch]$Status,
    [switch]$Apply,
    [switch]$Revert,
    [string]$T3Dir      = '',
    [string]$AsarPath   = '',
    [string]$ConfigPath = (Join-Path $HOME '.t3\local-patches.json'),
    [string]$BackupDir  = (Join-Path $env:LOCALAPPDATA 'T3CodeEnhanced\backups')
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    Write-Output 'run with pwsh 7 (the asar header JSON is too large for Windows PowerShell 5.1)'
    exit 1
}

$ErrorActionPreference = 'Stop'
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$bt = [char]96   # backtick, kept out of double-quoted strings
$nl = [char]10
$I  = '[A-Za-z_$][\w$]*'

$mode = if ($Apply -and -not $Revert) { 'Apply' }
        elseif ($Revert -and -not $Apply) { 'Revert' }
        else { 'Status' }
if ($Apply -and $Revert) { Write-Output 'note: -Apply and -Revert both given - reporting status only' }

. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $AsarPath) {
    if (-not $T3Dir) { $T3Dir = Find-T3Dir }
    if (-not $T3Dir) { Write-Output 'refusing: T3 Code install folder not found; pass -T3Dir'; exit 1 }
    $AsarPath = Join-Path $T3Dir 'resources\server.asar'
}
if (-not (Test-Path -LiteralPath $AsarPath)) { Write-Output "refusing: server.asar not found at $AsarPath - investigate"; exit 1 }
$sizeBefore = (Get-Item -LiteralPath $AsarPath).Length
$shaBefore  = (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash

# --- asar header: data starts at 8 + pickleSize --------------------------------
$fs = [System.IO.File]::Open($AsarPath, 'Open', 'Read', 'ReadWrite')
$br = New-Object System.IO.BinaryReader($fs)
$fs.Position = 4
$headerPickleSize = $br.ReadUInt32()
$fs.Position = 8
$headerBytes = $br.ReadBytes([int]$headerPickleSize)
$br.Close(); $fs.Close()

$jsonStart = 0
while ($headerBytes[$jsonStart] -ne 0x7b) { $jsonStart++ }
$jsonEnd = $headerBytes.Length - 1
while ($headerBytes[$jsonEnd] -ne 0x7d) { $jsonEnd-- }
$header = ([System.Text.Encoding]::UTF8.GetString($headerBytes[$jsonStart..$jsonEnd]) | ConvertFrom-Json)
$dataOffset = 8 + $headerPickleSize

# --- inventory: every file entry in the archive --------------------------------
$script:files = New-Object System.Collections.ArrayList
function Walk($node, $prefix) {
    if ($node.files) {
        foreach ($p in $node.files.PSObject.Properties) { Walk $p.Value ($prefix + '/' + $p.Name) }
    }
    elseif ($node.PSObject.Properties['offset'] -and $node.PSObject.Properties['size']) {
        [void]$script:files.Add([pscustomobject]@{ Path = $prefix; Offset = [int64]$node.offset; Size = [int64]$node.size })
    }
}
Walk $header ''

# --- chunk text cache (fresh reads only; cleared before any re-audit) ----------
$script:loaded = @{}
function Get-ChunkText([int64]$off, [int64]$size) {
    if (-not $script:loaded.ContainsKey($off)) {
        $f = [System.IO.File]::Open($AsarPath, 'Open', 'Read', 'ReadWrite')
        try {
            $f.Position = $dataOffset + $off
            $b = New-Object byte[] ([int]$size)
            $null = $f.Read($b, 0, [int]$size)
            $script:loaded[$off] = $Latin1.GetString($b)
        } finally { $f.Close() }
    }
    return $script:loaded[$off]
}
function Clear-ChunkCache { $script:loaded = @{} }

$script:jsCheck = Get-JsChecker $(if ($T3Dir) { $T3Dir } else { Split-Path (Split-Path $AsarPath) })
function Test-Syntax([string]$Text) {
    if (-not $script:jsCheck) { return 'skipped (no node and no T3 Code binary to check with)' }
    $tmp = Join-Path $env:TEMP ('t3e-check-{0}.mjs' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.File]::WriteAllBytes($tmp, $Latin1.GetBytes($Text))
    $r = & $script:jsCheck $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($r.Code -eq 0) { return 'ok' }
    return ('FAILED: ' + $r.Output.Trim())
}

# --- patch 1: slow-RPC threshold ------------------------------------------------
function Resolve-SlowRpc([string]$direction) {
    $anchor = 'slow-rpc-ack-requests'
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if ($t.Contains($anchor)) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hits.Count -eq 0) { return @{ State = 'UNKNOWN'; Detail = "anchor '$anchor' not found in any client asset chunk"; Edits = @() } }
    if ($hits.Count -gt 1) {
        $paths = ($hits | ForEach-Object { $_.Chunk.Path }) -join ', '
        return @{ State = 'UNKNOWN'; Detail = "anchor found in $($hits.Count) chunks - ambiguous ($paths)"; Edits = @() }
    }
    $h = $hits[0]
    $text = $h.Text
    # 2026-10-24: up to three plain constants may sit between <h> and <g>
    # (the 10-21 build added MAX_TRACKED_RPC_ACK_REQUESTS=256 there)
    $mid    = '(?:[\w$]+=[\w$.]+,){0,3}'
    $mOrig  = [regex]::Matches($text, '([\w$]+)=15e3,([\w$]+)=12e4,' + $mid + '[\w$]+=\1(?![\w$])')
    $mPatch = [regex]::Matches($text, '([\w$]+)=60e3,([\w$]+)=12e4,' + $mid + '[\w$]+=\1(?![\w$])')
    if ($mOrig.Count -eq 0 -and $mPatch.Count -eq 0) {
        return @{ State = 'UNKNOWN'; Detail = 'threshold shape (<v>=15e3|60e3,<h>=12e4,...,<g>=<v>) not found in tracker chunk'; Edits = @() }
    }
    if ($mOrig.Count -gt 1 -or $mPatch.Count -gt 1) {
        return @{ State = 'UNKNOWN'; Detail = 'threshold shape matched more than once - ambiguous'; Edits = @() }
    }
    $name = Split-Path $h.Chunk.Path -Leaf
    $short = "chunk $name (offset $($h.Chunk.Offset), size $($h.Chunk.Size))"
    if ($mPatch.Count -eq 1) {
        $edits = @()
        if ($direction -eq 'stock') {
            $rel = $text.IndexOf('60e3', $mPatch[0].Index, $mPatch[0].Length)
            $edits = @(@{ Kind = 'region'; Patch = 'slowrpc'; Off = [int64]($dataOffset + $h.Chunk.Offset + $rel); Old = '60e3'; New = '15e3'; Chunk = $h.Chunk; ChunkText = $text })
        }
        return @{ State = 'PATCHED'; Detail = "$short, threshold 60e3"; Edits = $edits }
    }
    $edits = @()
    if ($direction -eq 'patched') {
        $rel = $text.IndexOf('15e3', $mOrig[0].Index, $mOrig[0].Length)
        $edits = @(@{ Kind = 'region'; Patch = 'slowrpc'; Off = [int64]($dataOffset + $h.Chunk.Offset + $rel); Old = '15e3'; New = '60e3'; Chunk = $h.Chunk; ChunkText = $text })
    }
    return @{ State = 'ORIGINAL'; Detail = "$short, threshold 15e3 (stock)"; Edits = $edits }
}

# --- patch 2: OpenCode cold-start budgets ---------------------------------------
# Sites are located by their bundled source-file region comments, so minified
# identifier renames in future builds do not break the match. The stock digits
# (5/5/4) are kept per site so -Revert restores them exactly.
$sites = @(
    @{ Name = 'model-list budget (makeOpenCode2ModelLoader)'; Region = 'packages/provider-opencode/src/server/status.ts'
       OrigRe = 'timeoutOption\("5 seconds"\)'; PatchRe = 'timeoutOption\("9 seconds"\)'; Stock = '5'
       UpstreamFixedRe = 'timeoutOption\(resolveProviderProbeTimeoutMs\("opencode", 1e4,' },   # 2026-11-14 build: 10 s
    # 2026-11-14 build: the constant became INFO_TIMEOUT_MS = 5e3 (milliseconds); 5e3 -> 9e3 keeps the length
    @{ Name = '/api/info readiness (INFO_TIMEOUT)'; Region = 'packages/provider-opencode/src/server/v2/OpenCode2Server.ts'
       OrigRe = 'const \w+ = "5 seconds";|const INFO_TIMEOUT_MS = 5e3;'; PatchRe = 'const \w+ = "9 seconds";|const INFO_TIMEOUT_MS = 9e3;'; Stock = '5' },
    @{ Name = 'version probe (OPENCODE_VERSION_PROBE_TIMEOUT)'; Region = 'packages/provider-opencode/src/server/versionProbe.ts'
       OrigRe = 'const \w+ = "4 seconds";'; PatchRe = 'const \w+ = "9 seconds";'; Stock = '4'
       UpstreamFixedRe = 'const \w+ = "10 seconds";|const OPENCODE_VERSION_PROBE_TIMEOUT_MS = 1e4;' }
)

function Resolve-OpenCode([string]$direction) {
    $mjs = @($script:files | Where-Object { $_.Path -match '/apps/server/dist/[^/]+\.mjs$' })
    if ($mjs.Count -eq 0) { return @{ State = 'UNKNOWN'; Detail = 'no apps/server/dist/*.mjs chunk in the asar'; Edits = @() } }
    $siteResults = @()
    $edits = @()
    foreach ($s in $sites) {
        $regionChunks = @($mjs | Where-Object { (Get-ChunkText $_.Offset $_.Size).Contains($s.Region) })
        if ($regionChunks.Count -eq 0) { $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = "region '$($s.Region)' not found" }; continue }
        if ($regionChunks.Count -gt 1) { $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = "region found in $($regionChunks.Count) chunks - ambiguous" }; continue }
        $chunk = $regionChunks[0]
        $text = Get-ChunkText $chunk.Offset $chunk.Size
        $mark = $null
        foreach ($r in [regex]::Matches($text, '//#region ([^\r\n]+)')) {
            if ($r.Groups[1].Value.Contains($s.Region)) { $mark = $r; break }
        }
        # 2026-10-29: builds from 0.0.5x on drop the //#region pair. Each source file starts with an inline
        # `// ../../packages/<file>` comment, and the file runs until the next such comment.
        if (-not $mark) {
            foreach ($r in [regex]::Matches($text, '// \.\./\.\./(packages/[^\s;]+)')) {
                if ($r.Groups[1].Value -eq $s.Region) { $mark = $r; break }
            }
        }
        if (-not $mark) { $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = "region marker for '$($s.Region)' not found" }; continue }
        $rStart = $mark.Index
        if ($mark.Value.StartsWith('//#region')) {
            $endMark = $text.IndexOf('//#endregion', $rStart)
        } else {
            $next = [regex]::Match($text.Substring($rStart + 1), '// \.\./\.\./packages/')
            $endMark = if ($next.Success) { $rStart + 1 + $next.Index } else { -1 }
        }
        $sliceLen = if ($endMark -lt 0) { $text.Length - $rStart } else { $endMark - $rStart }
        $slice = $text.Substring($rStart, $sliceLen)
        $mOrigS  = [regex]::Matches($slice, $s.OrigRe)
        $mPatchS = [regex]::Matches($slice, $s.PatchRe)
        if ($mOrigS.Count -eq 0 -and $mPatchS.Count -eq 0) {
            if ($s.UpstreamFixedRe -and [regex]::Matches($slice, $s.UpstreamFixedRe).Count -eq 1) {
                # neutral: counts as neither stock nor patched, so -Revert can reach ORIGINAL
                $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UPSTREAM'; Detail = 'upstream raised the timeout itself; patch unnecessary' }
                continue
            }
            $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = 'neither stock nor patched shape found in region' }; continue
        }
        if ($mOrigS.Count + $mPatchS.Count -gt 1) { $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = 'shape matched more than once in region - ambiguous' }; continue }
        $isPatched = $mPatchS.Count -eq 1
        $wantEdit = ($direction -eq 'patched' -and -not $isPatched) -or ($direction -eq 'stock' -and $isPatched)
        if ($wantEdit) {
            $m = if ($isPatched) { $mPatchS[0] } else { $mOrigS[0] }
            $digit = if ($direction -eq 'patched') { '9' } else { $s.Stock }
            $newVal = if ($m.Value -match '"\d+ seconds"') { [regex]::Replace($m.Value, '"\d+ seconds"', ('"' + $digit + ' seconds"')) }
                      else { [regex]::Replace($m.Value, '= \de3;', ('= ' + $digit + 'e3;')) }
            if ($newVal.Length -ne $m.Value.Length) { $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = 'replacement length differs, refusing to write' }; continue }
            $edits += @{ Kind = 'region'; Patch = 'opencode'; Off = [int64]($dataOffset + $chunk.Offset + $rStart + $m.Index); Old = $m.Value; New = $newVal; Chunk = $chunk; ChunkText = $text }
        }
        $siteResults += [pscustomobject]@{ Name = $s.Name; State = if ($isPatched) { 'PATCHED' } else { 'ORIGINAL' }; Detail = $null }
    }
    $st = @($siteResults | ForEach-Object State | Where-Object { $_ -ne 'UPSTREAM' })
    $overall = 'MIXED'
    if ($st -contains 'UNKNOWN') { $overall = 'UNKNOWN' }
    elseif (@($st | Where-Object { $_ -ne 'PATCHED' }).Count -eq 0) { $overall = 'PATCHED' }
    elseif (@($st | Where-Object { $_ -ne 'ORIGINAL' }).Count -eq 0) { $overall = 'ORIGINAL' }
    $detail = ($siteResults | ForEach-Object { "$(($_.Name -replace ' \(.+\)',''))=$($_.State)" }) -join ', '
    return @{ State = $overall; Detail = $detail; Edits = $edits }
}

# --- patch 3: no-terminal v3 -----------------------------------------------------
function Resolve-NoTermV3([string]$direction) {
    $reA  = 'if\((?<fn>@I@)\(\{threadId:(?<tv>@I@),cwd:(?<cv>@I@),worktreePath:(?<wv>@I@)\}\),(?<so>@I@)\(!0\),!(?<xv>@I@)\)return;'.Replace('@I@', $I)
    $rePA = 'if\((?<fn>@I@)\(\{threadId:(?<tv>@I@),cwd:(?<cv>@I@),worktreePath:(?<wv>@I@)\}\),\((?<fa>@I@)=(?<param>@I@)\.id===`chat-code-block`\)&&(?<so>@I@)\(!0\),!(?<xv>@I@)\)return;'.Replace('@I@', $I)
    $reD  = '(?<a>@I@)=(?<xo>@I@)\.includes\((?<ii>@I@)\),(?<o>@I@)=!!(?<pt>@I@)\?\.preferNewTerminal\|\|\k<a>\|\|'.Replace('@I@', $I)
    $reB  = 'place:(?<pe>@I@)=>(?<o>@I@)\?(?<nt>@I@)\((?<xa>@I@),\k<pe>\):(?<sa>@I@)\((?<xa2>@I@),\k<pe>\)'.Replace('@I@', $I)
    $rePB = 'place:(?<pe>@I@)=>\((?<o>@I@)&&(?<fa>@I@)\?(?<nt>@I@):(?<sa>@I@)\)\((?<xa>@I@),\k<pe>\)'.Replace('@I@', $I)
    $reH  = 'async\((?<p1>@I@),@I@\)=>\{'.Replace('@I@', $I)

    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/_chat-[A-Za-z0-9_-]+\.js$' -and $_.Size -gt 400000 })
    $target = $null
    foreach ($c in $cands) {
        $text = Get-ChunkText $c.Offset $c.Size
        $hit = [regex]::Match($text, $reA); if (-not $hit.Success) { $hit = [regex]::Match($text, $rePA) }
        if (-not $hit.Success) { continue }
        $probeStart = [Math]::Max(0, $hit.Index - 100)
        $probe = $text.Substring($probeStart, [Math]::Min(2500, $text.Length - $probeStart))
        if ($probe -notmatch 'chat-code-block') { continue }
        if ($target) { return @{ State = 'UNKNOWN'; Detail = 'more than one candidate chat chunk matches the shape - ambiguous'; Edits = @() } }
        $target = @{ Chunk = $c; Text = $text }
    }
    if (-not $target) {
        # --- v4 shape (2026-10-19 8:06 PM nightly, build 049AFF0E, and later) ----
        # Upstream removed the setTerminalOpen call from the run gate and folded
        # the prefer-new-terminal decision into the terminal resolution. Same
        # behavior as v3: only chat-code-block runs may open the bottom panel;
        # project-script runs attach with open:false in the background. Proven by
        # scripts\2026-10-19-noterm-v4-probe.js (round trip exact, node --check ok).
        $reA4  = '(?<av>@I@)=(?<lhs>[^;,]*?)\?\?null;if\((?<w>@I@)\(\{threadId:(?<tv>@I@),cwd:(?<cv>@I@),worktreePath:(?<wv>@I@)\}\),!(?<yv>@I@)\)return;'.Replace('@I@', $I)
        $rePA4 = ( '(?<av>@I@)=(?<lhs>[^;,]*?)\?\?null,(?<fv>@I@)=(?<pid>@I@)\.id===' + $bt + 'chat-code-block' + $bt + ';if\((?<w>@I@)\(\{threadId:(?<tv>@I@),cwd:(?<cv>@I@),worktreePath:(?<wv>@I@)\}\),!(?<yv>@I@)\)return;' ).Replace('@I@', $I)
        $reB4  = 'place:(?<pe>@I@)=>(?<iv>@I@)===null\?(?<nt>@I@)\((?<xa>@I@),\k<pe>\):(?<sa>@I@)\((?<xa2>@I@),\k<pe>,\{open:!0\}\)'.Replace('@I@', $I)
        # 2026-10-21: the open flag must be {open:flag}, not {open:!flag}. The
        # 2026-10-19 v4 edit shipped the inverted form; on a project-script run the
        # handler's script id is never 'chat-code-block', so !flag evaluated to
        # open:true and the panel opened. Both variants count as PATCHED here;
        # Apply rewrites the inverted one into the corrected one.
        $rePB4 = 'place:(?<pe>@I@)=>(?<iv>@I@)===null&&(?<fv>@I@)\?(?<nt>@I@)\((?<xa>@I@),\k<pe>\):(?<sa>@I@)\((?<xa2>@I@),\k<pe>,\{open:(?<bang>!?)\k<fv>\}\)'.Replace('@I@', $I)
        $target4 = $null
        foreach ($c in $cands) {
            $text = Get-ChunkText $c.Offset $c.Size
            $hit = [regex]::Match($text, $reA4); if (-not $hit.Success) { $hit = [regex]::Match($text, $rePA4) }
            if (-not $hit.Success) { continue }
            $probeStart = [Math]::Max(0, $hit.Index - 100)
            $probe = $text.Substring($probeStart, [Math]::Min(4200, $text.Length - $probeStart))
            if ($probe -notmatch 'chat-code-block') { continue }
            if ($target4) { return @{ State = 'UNKNOWN'; Detail = 'more than one candidate chat chunk matches the v4 shape - ambiguous'; Edits = @() } }
            $target4 = @{ Chunk = $c; Text = $text }
        }
        if ($target4) {
            $chunk = $target4.Chunk
            $text = $target4.Text
            $name = Split-Path $chunk.Path -Leaf
            $tail = $nl + '//# sourceMappingURL=' + $name + '.map'
            $cntA4  = ([regex]::Matches($text, $reA4)).Count
            $cntPA4 = ([regex]::Matches($text, $rePA4)).Count
            $cntB4  = ([regex]::Matches($text, $reB4)).Count
            $cntPB4 = ([regex]::Matches($text, $rePB4)).Count
            $short = "chunk $name (offset $($chunk.Offset), size $($chunk.Size))"
            if ($cntPA4 -eq 1 -and $cntPB4 -eq 1) {
                $edits = @()
                $mPA4 = [regex]::Match($text, $rePA4)
                $mPB4 = [regex]::Match($text, $rePB4)
                if ($mPA4.Groups['fv'].Value -ne $mPB4.Groups['fv'].Value) { return @{ State = 'UNKNOWN'; Detail = 'v4 flag variable differs between gate and place'; Edits = @() } }
                if ($mPB4.Groups['xa2'].Value -ne $mPB4.Groups['xa'].Value) { return @{ State = 'UNKNOWN'; Detail = 'v4 terminal thread argument differs between place branches'; Edits = @() } }
                if ($direction -eq 'patched' -and $mPB4.Groups['bang'].Value -eq '!') {
                    # 2026-10-21 fix: the 2026-10-19 v4 edit shipped {open:!flag}. On a
                    # project-script run the script id is not 'chat-code-block', so the
                    # flag is false and !flag opened the panel. Rewrite to {open:flag}
                    # (one byte; the pad absorbs it). Reverting this form reproduces
                    # stock byte-for-byte, so the split below is the only edit needed.
                    $wrongPlace = $mPB4.Value
                    $fv         = $mPB4.Groups['fv'].Value
                    $rightPlace = $wrongPlace.Replace('{open:!' + $fv + '}', '{open:' + $fv + '}')
                    $trimmed = if ($text.EndsWith($tail)) { $text.Substring(0, $text.Length - $tail.Length) } else { $text }
                    $newText = $trimmed.Replace($wrongPlace, $rightPlace)
                    if ($newText -eq $trimmed) { return @{ State = 'UNKNOWN'; Detail = 'v4 open-flag fix produced no change'; Edits = @() } }
                    $pad = $text.Length - $newText.Length
                    if ($pad -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'v4 open-flag fix would change chunk length'; Edits = @() } }
                    $newText = $newText + (' ' * $pad)
                    $edits = @(@{ Kind = 'chunk'; Patch = 'noterm-v3'; Chunk = $chunk; ChunkText = $text; NewChunkText = $newText })
                    return @{ State = 'PATCHED'; Detail = "$short, v4 gate present but open:!flag inverted - correcting to open:flag"; Edits = $edits }
                }
                if ($direction -eq 'stock') {
                    $cA = @{ av = $mPA4.Groups['av'].Value; lhs = $mPA4.Groups['lhs'].Value; w = $mPA4.Groups['w'].Value
                             tv = $mPA4.Groups['tv'].Value; cv = $mPA4.Groups['cv'].Value; wv = $mPA4.Groups['wv'].Value; yv = $mPA4.Groups['yv'].Value }
                    $cB = @{ pe = $mPB4.Groups['pe'].Value; iv = $mPB4.Groups['iv'].Value; nt = $mPB4.Groups['nt'].Value
                             sa = $mPB4.Groups['sa'].Value; xa = $mPB4.Groups['xa'].Value }
                    $oldA = $cA.av + '=' + $cA.lhs + '??null;if(' + $cA.w + '({threadId:' + $cA.tv + ',cwd:' + $cA.cv + ',worktreePath:' + $cA.wv + '}),!' + $cA.yv + ')return;'
                    $oldB = 'place:' + $cB.pe + '=>' + $cB.iv + '===null?' + $cB.nt + '(' + $cB.xa + ',' + $cB.pe + '):' + $cB.sa + '(' + $cB.xa + ',' + $cB.pe + ',{open:!0})'
                    $restored = $text.TrimEnd(' ').Replace($mPA4.Value, $oldA).Replace($mPB4.Value, $oldB) + $tail
                    if ($restored -eq $text) { return @{ State = 'PATCHED'; Detail = "$short, v4 rollback produced no change"; Edits = @() } }
                    if ($restored.Length -ne $text.Length) { return @{ State = 'UNKNOWN'; Detail = 'v4 revert would change chunk length'; Edits = @() } }
                    $edits = @(@{ Kind = 'chunk'; Patch = 'noterm-v3'; Chunk = $chunk; ChunkText = $text; NewChunkText = $restored })
                }
                return @{ State = 'PATCHED'; Detail = "$short, v4 chat-code-block gate"; Edits = $edits }
            }
            if ($cntA4 -eq 1 -and $cntB4 -eq 1) {
                $edits = @()
                if ($direction -eq 'patched') {
                    $mA4 = [regex]::Match($text, $reA4)
                    $mB4 = [regex]::Match($text, $reB4)
                    if ($mB4.Index -le $mA4.Index -or ($mB4.Index - $mA4.Index) -gt 2200) { return @{ State = 'UNKNOWN'; Detail = 'v4 place callback is not just after the run gate'; Edits = @() } }
                    $fv = $null
                    foreach ($cand in @('Z9', 'Zz', '$z9', 'qZ9')) { if ($text.IndexOf($cand, [System.StringComparison]::Ordinal) -lt 0) { $fv = $cand; break } }
                    if (-not $fv) { return @{ State = 'UNKNOWN'; Detail = 'no free flag variable name for the v4 patch'; Edits = @() } }
                    $hms = [regex]::Matches($text.Substring(0, $mA4.Index), $reH)
                    if ($hms.Count -eq 0) { return @{ State = 'UNKNOWN'; Detail = 'v4 run handler signature not found before the gate'; Edits = @() } }
                    $hm = $hms[$hms.Count - 1]
                    if (($mA4.Index - $hm.Index) -gt 2600) { return @{ State = 'UNKNOWN'; Detail = 'v4 nearest async handler too far before the gate'; Edits = @() } }
                    $param = $hm.Groups['p1'].Value
                    $pidIdx = $text.IndexOf(($param + '.id'), $hm.Index)
                    if ($pidIdx -lt 0 -or $pidIdx -gt $mA4.Index) { return @{ State = 'UNKNOWN'; Detail = "v4 handler parameter $param not used as a script id before the gate"; Edits = @() } }
                    $cA = @{ av = $mA4.Groups['av'].Value; lhs = $mA4.Groups['lhs'].Value; w = $mA4.Groups['w'].Value
                             tv = $mA4.Groups['tv'].Value; cv = $mA4.Groups['cv'].Value; wv = $mA4.Groups['wv'].Value; yv = $mA4.Groups['yv'].Value }
                    $cB = @{ pe = $mB4.Groups['pe'].Value; iv = $mB4.Groups['iv'].Value; nt = $mB4.Groups['nt'].Value
                             sa = $mB4.Groups['sa'].Value; xa = $mB4.Groups['xa'].Value }
                    if ($mB4.Groups['xa2'].Value -ne $cB.xa) { return @{ State = 'UNKNOWN'; Detail = 'v4 terminal thread argument differs between place branches'; Edits = @() } }
                    $newA = $cA.av + '=' + $cA.lhs + '??null,' + $fv + '=' + $param + '.id===' + $bt + 'chat-code-block' + $bt + ';if(' + $cA.w + '({threadId:' + $cA.tv + ',cwd:' + $cA.cv + ',worktreePath:' + $cA.wv + '}),!' + $cA.yv + ')return;'
                    $newB = 'place:' + $cB.pe + '=>' + $cB.iv + '===null&&' + $fv + '?' + $cB.nt + '(' + $cB.xa + ',' + $cB.pe + '):' + $cB.sa + '(' + $cB.xa + ',' + $cB.pe + ',{open:' + $fv + '})'
                    $trimmed = if ($text.EndsWith($tail)) { $text.Substring(0, $text.Length - $tail.Length) } else { $text }
                    $newText = $trimmed.Replace($mA4.Value, $newA).Replace($mB4.Value, $newB)
                    if ($newText -eq $trimmed) { return @{ State = 'ORIGINAL'; Detail = "$short, v4 replacement produced no change"; Edits = @() } }
                    $pad = $text.Length - $newText.Length
                    if ($pad -lt 0) { return @{ State = 'UNKNOWN'; Detail = "v4 replacement is $(-$pad) chars longer than the original - cannot preserve length"; Edits = @() } }
                    $newText = $newText + (' ' * $pad)
                    $edits = @(@{ Kind = 'chunk'; Patch = 'noterm-v3'; Chunk = $chunk; ChunkText = $text; NewChunkText = $newText })
                }
                return @{ State = 'ORIGINAL'; Detail = "$short, v4 stock gate (2026-10-19 handler)"; Edits = $edits }
            }
            if ($cntA4 -gt 1 -or $cntB4 -gt 1 -or $cntPA4 -gt 1 -or $cntPB4 -gt 1) {
                return @{ State = 'UNKNOWN'; Detail = 'v4 gate or place matched more than once - ambiguous'; Edits = @() }
            }
        }
    }
    return @{ State = 'UNKNOWN'; Detail = 'no _chat-*.js chunk matches the expected script-run shape (upstream restructure?)'; Edits = @() }

    $chunk = $target.Chunk
    $text = $target.Text
    $name = Split-Path $chunk.Path -Leaf
    $tail = $nl + '//# sourceMappingURL=' + $name + '.map'
    $cntA  = ([regex]::Matches($text, $reA)).Count
    $cntPA = ([regex]::Matches($text, $rePA)).Count
    $cntD  = ([regex]::Matches($text, $reD)).Count
    $cntB  = ([regex]::Matches($text, $reB)).Count
    $cntPB = ([regex]::Matches($text, $rePB)).Count
    $short = "chunk $name (offset $($chunk.Offset), size $($chunk.Size))"

    if ($cntPA -eq 1 -and $cntPB -eq 1 -and $cntD -eq 1) {
        $edits = @()
        if ($direction -eq 'stock') {
            $mPA = [regex]::Match($text, $rePA)
            $mPB = [regex]::Match($text, $rePB)
            $cA = @{ fn = $mPA.Groups['fn'].Value; tv = $mPA.Groups['tv'].Value; cv = $mPA.Groups['cv'].Value; wv = $mPA.Groups['wv'].Value
                     so = $mPA.Groups['so'].Value; xv = $mPA.Groups['xv'].Value }
            $cB = @{ pe = $mPB.Groups['pe'].Value; o = $mPB.Groups['o'].Value; fa = $mPB.Groups['fa'].Value; nt = $mPB.Groups['nt'].Value
                     sa = $mPB.Groups['sa'].Value; xa = $mPB.Groups['xa'].Value }
            $oldA = 'if(' + $cA.fn + '({threadId:' + $cA.tv + ',cwd:' + $cA.cv + ',worktreePath:' + $cA.wv + '}),' + $cA.so + '(!0),!' + $cA.xv + ')return;'
            $oldB = 'place:' + $cB.pe + '=>' + $cB.o + '?' + $cB.nt + '(' + $cB.xa + ',' + $cB.pe + '):' + $cB.sa + '(' + $cB.xa + ',' + $cB.pe + ')'
            $restored = $text.TrimEnd(' ').Replace($mPA.Value, $oldA).Replace($mPB.Value, $oldB) + $tail
            if ($restored -eq $text) { return @{ State = 'PATCHED'; Detail = "$short, rollback produced no change"; Edits = @() } }
            $edits = @(@{ Kind = 'chunk'; Patch = 'noterm-v3'; Chunk = $chunk; ChunkText = $text; NewChunkText = $restored })
        }
        return @{ State = 'PATCHED'; Detail = "$short, chat-code-block gate"; Edits = $edits }
    }
    if ($cntA -eq 1 -and $cntB -eq 1 -and $cntD -eq 1) {
        $edits = @()
        if ($direction -eq 'patched') {
            $mA = [regex]::Match($text, $reA)
            $mD = [regex]::Match($text, $reD)
            $mB = [regex]::Match($text, $reB)
            # the run handler's script parameter: nearest async(PARAM,ARG)=>{ before region A
            $hms = [regex]::Matches($text.Substring(0, $mA.Index), $reH)
            if ($hms.Count -eq 0) { return @{ State = 'UNKNOWN'; Detail = 'run handler signature not found before region A'; Edits = @() } }
            $hm = $hms[$hms.Count - 1]
            if (($mA.Index - ($hm.Index + $hm.Length)) -gt 2500) { return @{ State = 'UNKNOWN'; Detail = 'nearest async handler too far before region A'; Edits = @() } }
            if (-not ($mD.Index -gt $hm.Index -and $mD.Index -lt $mA.Index)) { return @{ State = 'UNKNOWN'; Detail = 'flag declaration is outside the run handler'; Edits = @() } }
            $param = $hm.Groups['p1'].Value
            $pidIdx = $text.IndexOf("$param.id", $hm.Index)
            if ($pidIdx -lt 0 -or $pidIdx -gt $mA.Index) { return @{ State = 'UNKNOWN'; Detail = "handler parameter $param not used as an object id before region A"; Edits = @() } }
            if ($mB.Groups['xa'].Value -ne $mB.Groups['xa2'].Value) { return @{ State = 'UNKNOWN'; Detail = 'terminal thread argument differs between place branches'; Edits = @() } }
            $cA = @{ fn = $mA.Groups['fn'].Value; tv = $mA.Groups['tv'].Value; cv = $mA.Groups['cv'].Value; wv = $mA.Groups['wv'].Value
                     so = $mA.Groups['so'].Value; xv = $mA.Groups['xv'].Value; fa = $mD.Groups['a'].Value; param = $param }
            $cB = @{ pe = $mB.Groups['pe'].Value; o = $mD.Groups['o'].Value; fa = $mD.Groups['a'].Value; nt = $mB.Groups['nt'].Value
                     sa = $mB.Groups['sa'].Value; xa = $mB.Groups['xa'].Value }
            if ($mB.Groups['o'].Value -ne $cB.o) { return @{ State = 'UNKNOWN'; Detail = 'place decision variable differs from the flag declaration'; Edits = @() } }
            $newA = 'if(' + $cA.fn + '({threadId:' + $cA.tv + ',cwd:' + $cA.cv + ',worktreePath:' + $cA.wv + '}),(' + $cA.fa + '=' + $cA.param + '.id===' + $bt + 'chat-code-block' + $bt + ')&&' + $cA.so + '(!0),!' + $cA.xv + ')return;'
            $newB = 'place:' + $cB.pe + '=>(' + $cB.o + '&&' + $cB.fa + '?' + $cB.nt + ':' + $cB.sa + ')(' + $cB.xa + ',' + $cB.pe + ')'
            $trimmed = if ($text.EndsWith($tail)) { $text.Substring(0, $text.Length - $tail.Length) } else { $text }
            $newText = $trimmed.Replace($mA.Value, $newA).Replace($mB.Value, $newB)
            if ($newText -eq $trimmed) { return @{ State = 'ORIGINAL'; Detail = "$short, replacement produced no change"; Edits = @() } }
            $pad = $text.Length - $newText.Length
            if ($pad -lt 0) { return @{ State = 'UNKNOWN'; Detail = "replacement is $(-$pad) chars longer than the original - cannot preserve length"; Edits = @() } }
            $newText = $newText + (' ' * $pad)
            $edits = @(@{ Kind = 'chunk'; Patch = 'noterm-v3'; Chunk = $chunk; ChunkText = $text; NewChunkText = $newText })
        }
        return @{ State = 'ORIGINAL'; Detail = "$short, no gate (stock)"; Edits = $edits }
    }
    return @{ State = 'UNKNOWN'; Detail = 'chunk found but neither original nor patched shape matched (upstream code changed)'; Edits = @() }
}

# --- patch 4: no-terminal open flag is final -------------------------------------
# apply the same policy: an upstream shape change skips only this patch.
function Resolve-NotermOpen([string]$direction) {
    $anchor = 'ensureTerminal:'
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if ($t.Contains($anchor)) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hits.Count -eq 0) { return @{ State = 'UNKNOWN'; Detail = "anchor 'ensureTerminal:' not found in any client asset chunk"; Edits = @() } }
    if ($hits.Count -gt 1) {
        $paths = ($hits | ForEach-Object { $_.Chunk.Path }) -join ', '
        return @{ State = 'UNKNOWN'; Detail = "anchor found in $($hits.Count) chunks - ambiguous ($paths)"; Edits = @() }
    }
    $chunk = $hits[0].Chunk
    $text = $hits[0].Text
    $name = Split-Path $chunk.Path -Leaf
    $short = "chunk $name (offset $($chunk.Offset), size $($chunk.Size))"
    # signature: ensureTerminal:(e,t,r)=>, then the body within a bounded window
    $hdr = 'ensureTerminal:\((?<e>@I@),(?<tp>@I@),(?<op>@I@)\)=>'.Replace('@I@', $I)
    $mHdr = [regex]::Match($text, $hdr)
    if (-not $mHdr.Success) { return @{ State = 'UNKNOWN'; Detail = 'ensureTerminal signature shape not found'; Edits = @() } }
    $winLen = [Math]::Min(800, $text.Length - $mHdr.Index)
    $win = $text.Substring($mHdr.Index, $winLen)
    # creation path: e.terminalIds.includes(t)||(n=ct(n,t)) - the receiver must be
    # the state param from the signature; this rejects the activation (lt) call,
    # which otherwise matches the same loose shape.
    $tpName = $mHdr.Groups['tp'].Value
    $eName  = $mHdr.Groups['e'].Value
    $reCreate = ('(?<x>@I@)\.terminalIds\.includes\(' + $tpName + '\)\|\|\((?<st>@I@)=(?<ct>@I@)\(\k<st>,' + $tpName + '\)\)').Replace('@I@', $I)
    $cntCreate = ([regex]::Matches($win, $reCreate)).Count
    if ($cntCreate -ne 1) { return @{ State = 'UNKNOWN'; Detail = "ensureTerminal creation path matched $cntCreate times (expected 1)"; Edits = @() } }
    # stock tail: r?.open&&(n=ot(n,!0))
    $reO = '(?<op2>@I@)\?\.open&&\((?<st2>@I@)=(?<os>@I@)\(\k<st2>,!0\)\)'.Replace('@I@', $I)
    # patched tail: (n=ot(n,r&&!!r.open))
    $reP = '\((?<st3>@I@)=(?<os2>@I@)\(\k<st3>,(?<op3>@I@)&&!!\k<op3>\.open\)\)'.Replace('@I@', $I)
    $cntO = ([regex]::Matches($win, $reO)).Count
    $cntP = ([regex]::Matches($win, $reP)).Count
    if ($cntO -eq 0 -and $cntP -eq 0) {
        return @{ State = 'UNKNOWN'; Detail = 'neither stock nor patched open-flag tail found in the ensureTerminal body'; Edits = @() }
    }
    if ($cntO + $cntP -gt 1) {
        return @{ State = 'UNKNOWN'; Detail = "open-flag tail matched more than once - ambiguous ($cntO stock, $cntP patched)"; Edits = @() }
    }
    $mO = [regex]::Match($win, $reO)
    $mP = [regex]::Match($win, $reP)
    if ($cntO -eq 1) {
        $op2 = $mO.Groups['op2'].Value
        $st2 = $mO.Groups['st2'].Value
        $mC = [regex]::Match($win, $reCreate)
        $st1 = $mC.Groups['st'].Value
        if ($mC.Groups['x'].Value -ne $eName) { return @{ State = 'UNKNOWN'; Detail = 'creation-path receiver differs from the ensureTerminal state parameter'; Edits = @() } }
        $os1 = $mO.Groups['os'].Value
        if ($op2 -ne $mHdr.Groups['op'].Value) { return @{ State = 'UNKNOWN'; Detail = 'open-flag variable differs from the ensureTerminal options parameter'; Edits = @() } }
        if ($st2 -ne $st1) { return @{ State = 'UNKNOWN'; Detail = 'reducer variable differs between creation path and open-flag tail'; Edits = @() } }
        if ($os1 -eq $op2 -or $os1 -eq $st2) { return @{ State = 'UNKNOWN'; Detail = 'open setter name collides with a captured variable'; Edits = @() } }
        $state = 'ORIGINAL'
        $relIdx = $mO.Index
        $old = $mO.Value
        $new = '(' + $st2 + '=' + $os1 + '(' + $st2 + ',' + $op2 + '&&!!' + $op2 + '.open))'
    }
    else {
        $op3 = $mP.Groups['op3'].Value
        $st3 = $mP.Groups['st3'].Value
        $os2 = $mP.Groups['os2'].Value
        if ($op3 -ne $mHdr.Groups['op'].Value) { return @{ State = 'UNKNOWN'; Detail = 'open-flag variable differs from the ensureTerminal options parameter'; Edits = @() } }
        $state = 'PATCHED'
        $relIdx = $mP.Index
        # revert: the bytes in the file are the patched tail; restore the stock tail
        $old = $mP.Value
        $new = $op3 + '?.open&&(' + $st3 + '=' + $os2 + '(' + $st3 + ',!0))'
    }
    if ($old.Length -ne $new.Length) {
        return @{ State = 'UNKNOWN'; Detail = "open-flag replacement length differs ($($old.Length) -> $($new.Length)); refusing to write"; Edits = @() }
    }
    $absOff = $dataOffset + $chunk.Offset + $mHdr.Index + $relIdx
    $edits = @()
    if (($state -eq 'ORIGINAL' -and $direction -eq 'patched') -or ($state -eq 'PATCHED' -and $direction -eq 'stock')) {
        $edits = @(@{ Kind = 'region'; Patch = 'noterm-open'; Off = [int64]$absOff; Old = $old; New = $new; Chunk = $chunk; ChunkText = $text })
    }
    $flagKind = if ($state -eq 'PATCHED') { 'open flag is final (close-capable)' } else { 'open flag is an upward bump only (stock)' }
    return @{ State = $state; Detail = "$short, $flagKind"; Edits = $edits }
}

# --- patch 5: hiding the right panel never floats the preview --------------------
# Source (useRightPanelActions.ts closePreviewPanel): a preview or device surface is
# moved into the mini-player with usePreviewMiniPlayerStore.getState().open(ref, ...),
# then the panel is un-maximized and closed. Only the two open() calls change:
#   M.getState().open(R,   ->   !1&&M.getState()(R,    (same length, never evaluated)
# Every name is captured; a site counts only when the same R is passed to
# .setMaximized(R,!1) and .close(R) right after it, which rules out the explicit
# picture-in-picture button and the agent-opened previews. Replaces
# 2026-10-18-t3-hide-no-float-v4.ps1, whose hard-coded minified names broke on
# every build.
function Resolve-NoFloat([string]$direction) {
    $anchor = '.getState().setMaximized('
    # preview: mp.getState().open(r,src(sv.resourceId))     -> !1&&mp.getState()(r, src(...))
    # device, builds to 2026-10:  mp.getState().open(r,{kind:`device`,...sv.target})  -> same edit
    # device, builds from 2026-11: &&sv.target&&dv(r,{kind:`device`,...sv.target},...) -> &&!1<spaces>&&dv(...)
    $shapes = @(
        @{ Kind = 'preview'; Form = 'open'
           Stock = '(?<mp>@I@)\.getState\(\)\.open\((?<r>@I@),(?<src>@I@)\((?<sv>@I@)\.resourceId\)\)'
           Patch = '!1&&(?<mp>@I@)\.getState\(\)\((?<r>@I@), (?<src>@I@)\((?<sv>@I@)\.resourceId\)\)' },
        @{ Kind = 'device'; Form = 'open'
           Stock = ('(?<mp>@I@)\.getState\(\)\.open\((?<r>@I@),\{kind:' + $bt + 'device' + $bt + ',\.\.\.(?<sv>@I@)\.target\}\)')
           Patch = ('!1&&(?<mp>@I@)\.getState\(\)\((?<r>@I@), \{kind:' + $bt + 'device' + $bt + ',\.\.\.(?<sv>@I@)\.target\}\)') },
        @{ Kind = 'device'; Form = 'guard'
           Stock = ('&&(?<sv>@I@)\.target&&(?<dv>@I@)\((?<r>@I@),\{kind:' + $bt + 'device' + $bt + ',\.\.\.\k<sv>\.target\}')
           Patch = ('&&!1(?<pad> +)&&(?<dv>@I@)\((?<r>@I@),\{kind:' + $bt + 'device' + $bt + ',\.\.\.(?<sv>@I@)\.target\}') }
    )
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $sites = @()
    foreach ($c in $cands) {
        $text = Get-ChunkText $c.Offset $c.Size
        if (-not $text.Contains($anchor)) { continue }
        foreach ($k in $shapes) {
            foreach ($pair in @(@('ORIGINAL', $k.Stock), @('PATCHED', $k.Patch))) {
                foreach ($m in [regex]::Matches($text, $pair[1].Replace('@I@', $I))) {
                    if ($k.Form -eq 'guard' -and $pair[0] -eq 'PATCHED' -and $m.Groups['pad'].Length -ne $m.Groups['sv'].Length + 5) { continue }
                    $r = [regex]::Escape($m.Groups['r'].Value)
                    $after = $text.Substring($m.Index + $m.Length, [Math]::Min(400, $text.Length - $m.Index - $m.Length))
                    $ctx = ('^[^;]{0,260}?(?<ps>@I@)\.getState\(\)\.setMaximized\(' + $r + ',!1\),\k<ps>\.getState\(\)\.close\(' + $r + '\)').Replace('@I@', $I)
                    if (-not [regex]::IsMatch($after, $ctx)) { continue }
                    $sites += [pscustomobject]@{ Kind = $k.Kind; Form = $k.Form; State = $pair[0]; Chunk = $c; Text = $text; M = $m }
                }
            }
        }
    }
    foreach ($kind in 'preview', 'device') {
        $n = @($sites | Where-Object Kind -eq $kind).Count
        if ($n -ne 1) { return @{ State = 'UNKNOWN'; Detail = "$kind float site matched $n times (expected 1)"; Edits = @() } }
    }
    $p = $sites | Where-Object Kind -eq 'preview'
    $d = $sites | Where-Object Kind -eq 'device'
    if ($p.Chunk.Offset -ne $d.Chunk.Offset) { return @{ State = 'UNKNOWN'; Detail = 'preview and device float sites are in different chunks'; Edits = @() } }
    $same = if ($d.Form -eq 'open') { 'mp', 'r', 'sv' } else { , 'r' }
    foreach ($g in $same) {
        if ($p.M.Groups[$g].Value -ne $d.M.Groups[$g].Value) { return @{ State = 'UNKNOWN'; Detail = "float sites disagree on the captured '$g' name"; Edits = @() } }
    }
    $chunk = $p.Chunk
    $name = Split-Path $chunk.Path -Leaf
    $short = "chunk $name (offset $($chunk.Offset), size $($chunk.Size))"
    $edits = @()
    foreach ($s in @($p, $d)) {
        $r = $s.M.Groups['r'].Value
        if ($s.Form -eq 'open') {
            $mp = $s.M.Groups['mp'].Value
            $stockHead = $mp + '.getState().open(' + $r + ','
            $patchHead = '!1&&' + $mp + '.getState()(' + $r + ', '
            $at = 0
        } else {
            $sv = $s.M.Groups['sv'].Value
            $stockHead = $sv + '.target'
            $patchHead = '!1' + (' ' * ($sv.Length + 5))
            $at = 2
        }
        if ($stockHead.Length -ne $patchHead.Length) { return @{ State = 'UNKNOWN'; Detail = 'float edit would change length'; Edits = @() } }
        if ($s.State -eq 'ORIGINAL' -and $direction -eq 'patched') { $old = $stockHead; $new = $patchHead }
        elseif ($s.State -eq 'PATCHED' -and $direction -eq 'stock') { $old = $patchHead; $new = $stockHead }
        else { continue }
        $edits += @{ Kind = 'region'; Patch = 'nofloat'; Off = [int64]($dataOffset + $chunk.Offset + $s.M.Index + $at); Old = $old; New = $new; Chunk = $chunk; ChunkText = $s.Text }
    }
    $state = if ($p.State -eq $d.State) { $p.State } else { 'MIXED' }
    return @{ State = $state; Detail = "$short, preview=$($p.State), device=$($d.State) ($($d.Form) form)"; Edits = $edits }
}


# --- patch 7: galaxy sidebar header stays with a custom theme ---------------------
# Stock T3 draws the galaxy artwork behind the sidebar header only until it sees a
# palette theme that does not opt in (sidebarArtwork), then swaps it for a "Nightly"
# pill. Two same-length edits (2026-10-24; see notes\2026-10-24-t3-galaxy-header.md):
#   A  settings chunk, the mode resolver: the "palette theme without artwork -> pill"
#      branch is cut out (the condition becomes !1 plus spaces), so the chosen mode
#      (artwork by default) always stands.
#   B  main chunk, the sidebar header: the pill label also shows in artwork mode
#      (=I===`pill`? becomes =I!=`none` ?), so the Nightly label and the version add-on
#      (~/.t3/local-version-badge.js) sit on top of the galaxy.
function Resolve-Galaxy([string]$direction) {
    $bq = [string]$bt
    # the guard after the cut is `e.mode===`artwork`` (builds to 0.1.6) or a local flag
    # `t` (= mode is neither pill nor none, 0.1.7-nightly.20261101+); both are accepted
    $guard = '(?:[\w$]+\.mode===' + $bq + 'artwork' + $bq + '|[\w$]+)\?' + $bq + 'pill' + $bq + ':'
    $reAStock = '(?<a>[\w$]+)\.paletteThemeActive&&!\k<a>\.paletteThemeAllowsArtwork&&(?=' + $guard + '\k<a>\.mode(?![\w$]))'
    $reAPatch = '!1&&(?<pad> +)(?=' + $guard + '(?<a>[\w$]+)\.mode(?![\w$]))'
    $reBStock = '(?<=[(,][\w$]+=)(?<i>[\w$]+)===' + $bq + 'pill' + $bq + '\?(?<k>[\w$]+\([\w$]+\)):null(?=,)'
    $reBPatch = '(?<=[(,][\w$]+=)(?<i>[\w$]+)!=' + $bq + 'none' + $bq + ' \?(?<k>[\w$]+\([\w$]+\)):null(?=,)'
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hitsA = @(); $hitsB = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if ($t.Contains('paletteThemeAllowsArtwork') -and $t.Contains('settingsHydrated')) { $hitsA += [pscustomobject]@{ Chunk = $c; Text = $t } }
        if ($t.Contains('sidebar-stage-backdrop pointer-events-none'))                    { $hitsB += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hitsA.Count -ne 1 -or $hitsB.Count -ne 1) {
        return @{ State = 'UNKNOWN'; Detail = "anchor chunks: settings $($hitsA.Count), sidebar $($hitsB.Count) (expected 1 each)"; Edits = @() }
    }
    $edits = @(); $states = @(); $notes = @()
    $sites = @(
        @{ Name = 'mode-resolver'; Hit = $hitsA[0]; Stock = $reAStock; Patch = $reAPatch },
        @{ Name = 'header-label';  Hit = $hitsB[0]; Stock = $reBStock; Patch = $reBPatch }
    )
    foreach ($s in $sites) {
        $text = $s.Hit.Text
        $ms = [regex]::Matches($text, $s.Stock, 'None')
        $mp = [regex]::Matches($text, $s.Patch, 'None')
        if ($ms.Count + $mp.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "$($s.Name) matched $($ms.Count) stock / $($mp.Count) patched (expected 1 total)"; Edits = @() } }
        if ($ms.Count -eq 1) {
            $m = $ms[0]; $states += 'ORIGINAL'
            if ($s.Name -eq 'mode-resolver') { $new = '!1&&' + (' ' * ($m.Length - 4)) }
            else { $new = $m.Groups['i'].Value + '!=' + $bq + 'none' + $bq + ' ?' + $m.Groups['k'].Value + ':null' }
            if ($new.Length -ne $m.Length) { return @{ State = 'UNKNOWN'; Detail = "$($s.Name) edit would change length"; Edits = @() } }
            if ($direction -eq 'patched') { $edits += @{ Kind = 'region'; Patch = 'galaxy'; Off = [int64]($dataOffset + $s.Hit.Chunk.Offset + $m.Index); Old = $m.Value; New = $new; Chunk = $s.Hit.Chunk; ChunkText = $text } }
        } else {
            $m = $mp[0]; $states += 'PATCHED'
            if ($s.Name -eq 'mode-resolver') {
                $a = $m.Groups['a'].Value
                $old = $a + '.paletteThemeActive&&!' + $a + '.paletteThemeAllowsArtwork&&'
            } else {
                $old = $m.Groups['i'].Value + '===' + $bq + 'pill' + $bq + '?' + $m.Groups['k'].Value + ':null'
            }
            if ($old.Length -ne $m.Length) { return @{ State = 'UNKNOWN'; Detail = "$($s.Name) revert would change length"; Edits = @() } }
            if ($direction -eq 'stock') { $edits += @{ Kind = 'region'; Patch = 'galaxy'; Off = [int64]($dataOffset + $s.Hit.Chunk.Offset + $m.Index); Old = $m.Value; New = $old; Chunk = $s.Hit.Chunk; ChunkText = $text } }
        }
        $notes += "$($s.Name) in $(Split-Path $s.Hit.Chunk.Path -Leaf)"
    }
    $state = if (@($states | Select-Object -Unique).Count -eq 1) { $states[0] } else { 'MIXED' }
    return @{ State = $state; Detail = ($notes -join ', '); Edits = $edits }
}

# --- patch 8: every project script is its own visible button ----------------------
# Stock T3 shows ONE script as a split button (run + chevron) and hides the others in
# the chevron's drop-down. The group is rendered once for the primary script; this
# renders it once per script (O.map). Every group keeps its own chevron (add/edit/import
# menu); each opens its own menu (shared state holds the group number, anchored on that
# group). Same length: the added code is paid for by shortening the
# "pair again" tooltip, which only shows when the client may not run terminal commands
# (2026-10-24; see notes\2026-10-24-t3-patch-hardening.md).
function Resolve-ScriptButtonsV1([string]$direction) {
    $bq = [string]$bt
    $anchor = 'role:' + $bq + 'group' + $bq + ',"aria-label":' + $bq + 'Project scripts' + $bq
    $tipStock = 'Pair this client again with permission to run terminal commands.'
    $tipShorts = @('Pair this client again to run scripts.', 'Pair again to run scripts.', 'Re-pair to run scripts.', 'Re-pair to run.', 'Re-pair.', 'Pair.')
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if ($t.Contains($anchor)) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "project-scripts anchor found in $($hits.Count) chunks (expected 1)"; Edits = @() } }
    $chunk = $hits[0].Chunk; $text = $hits[0].Text
    $short = "chunk $(Split-Path $chunk.Path -Leaf)"
    $jsx = '\(0,\$\.jsxs\)\((?<Y>@I@),\{role:' + $bq + 'group' + $bq + ',"aria-label":' + $bq + 'Project scripts' + $bq + ',\.\.\.(?<V>@I@)\?\{className:(?<J>@I@),ref:'
    $jsxTail = '\}:\{\},children:\['
    $reStock = (':(?<E>@I@)\?(?<R>' + $jsx + '(?<B>@I@)' + $jsxTail + ')').Replace('@I@', $I)
    $rePatch = (':(?<E>@I@)\?(?<O>@I@)\.map\(\(\k<E>,(?<Ix>@I@),(?<L>@I@),(?<Z>@I@)=\k<O>\[\k<Ix>\+1\]\)=>(?<R>' + $jsx + '\k<Z>\?\k<L>=>(?<B>@I@)\[\k<Ix>\]=\k<L>:(?<B2>@I@)' + $jsxTail + ')').Replace('@I@', $I)
    $reEndS = ('\]\}\):(?<O>@I@)\.length>0\|\|(?<N>@I@)\.length>0\?').Replace('@I@', $I)
    $reEndP = ('\]\}\)\)(?<pad> *):(?<O>@I@)\.length>0\|\|(?<N>@I@)\.length>0\?').Replace('@I@', $I)
    $ms = [regex]::Matches($text, $reStock)
    $mp = [regex]::Matches($text, $rePatch)
    if ($ms.Count + $mp.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "group head matched $($ms.Count) stock / $($mp.Count) patched (expected 1 total)"; Edits = @() } }
    $isStock = $ms.Count -eq 1
    $m = if ($isStock) { $ms[0] } else { $mp[0] }
    $c = $m.Groups
    $afterHead = $m.Index + $m.Length
    $me = [regex]::Match($text.Substring($afterHead, [Math]::Min(2500, $text.Length - $afterHead)), $(if ($isStock) { $reEndS } else { $reEndP }))
    if (-not $me.Success) { return @{ State = 'UNKNOWN'; Detail = 'end of the project-scripts group not found'; Edits = @() } }
    $bodyStart = $m.Index + 1 + $c['E'].Length + 1          # after ':E?'
    $endAt = $afterHead + $me.Index + 3                      # through ']})'
    if (-not $isStock) { $endAt += 1 + $me.Groups['pad'].Length }   # ']}))' plus pad
    $region = $text.Substring($bodyStart, $endAt - $bodyStart)
    $oName = $me.Groups['O'].Value
    $eN = $c['E'].Value; $vN = $c['V'].Value; $bN = $c['B'].Value
    $dividerStock = $vN + '?(0,$.jsx)(' + $bq + 'span' + $bq + ',{"aria-hidden":' + $bq + 'true' + $bq + ',className:'
    if ($isStock) {
        if (([regex]::Matches($region, [regex]::Escape($tipStock))).Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = 'tooltip text not found exactly once in the scripts group'; Edits = @() } }
        $divM = [regex]::Matches($region, ([regex]::Escape($dividerStock) + '@I@\}\):\(0,\$\.jsx\)\(@I@,\{className:' + $bq + 'hidden @3xl/header-actions:block' + $bq + '\}\),').Replace('@I@', $I))
        $chevM = [regex]::Matches($region, ('\(0,\$\.jsxs\)\(@I@,\{open:@I@\.scripts,').Replace('@I@', $I))
        if ($divM.Count -ne 1 -or $chevM.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "divider matched $($divM.Count), chevron matched $($chevM.Count) (expected 1 each)"; Edits = @() } }
        if ($chevM[0].Index -lt $divM[0].Index) { return @{ State = 'UNKNOWN'; Detail = 'chevron precedes divider'; Edits = @() } }
        $cm = [regex]::Match($region, ('\(0,\$\.jsxs\)\(@I@,\{open:(?<C>@I@)\.scripts,onOpenChange:(?<e>@I@)=>@I@\(\{presentation:@I@,scripts:\k<e>,imports:!1\}\),children:\[').Replace('@I@', $I))
        if (-not $cm.Success) { return @{ State = 'UNKNOWN'; Detail = 'chevron open-state shape not found'; Edits = @() } }
        # three unused one-letter names for the map callback
        $free = @()
        foreach ($ch in [char[]]'ILZQWKJHGFDSAPMNBXUTRYqjkzxwp') {
            if (-not [regex]::IsMatch($region, '(?<![\w$])' + [regex]::Escape([string]$ch) + '(?![\w$])') -and [string]$ch -ne $oName -and [string]$ch -ne $eN) { $free += [string]$ch }
            if ($free.Count -eq 3) { break }
        }
        if ($free.Count -lt 3) { return @{ State = 'UNKNOWN'; Detail = 'no free identifiers for the map callback'; Edits = @() } }
        $nI = $free[0]; $nL = $free[1]; $nZ = $free[2]
        $new = $region
        # every group keeps its own chevron: the menu is open when the shared state holds
        # this group's number (index + 1), and every group but the last anchors its menu on its own element
        $cOld = $cm.Value
        $cNew = $cOld.Replace('open:' + $cm.Groups['C'].Value + '.scripts,', 'open:' + $cm.Groups['C'].Value + '.scripts==' + $nI + '+1,').Replace(',scripts:' + $cm.Groups['e'].Value + ',imports', ',scripts:' + $cm.Groups['e'].Value + '&&' + $nI + '+1,imports')
        if ($cNew.Length -ne $cOld.Length + 10) { return @{ State = 'UNKNOWN'; Detail = 'chevron rewrite did not apply'; Edits = @() } }
        $new = $new.Replace($cOld, $cNew)
        $anchorStock = '...' + $vN + '?{anchor:' + $bN + '}:{}'
        if (([regex]::Matches($new, [regex]::Escape($anchorStock))).Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = 'menu anchor not found exactly once'; Edits = @() } }
        $new = $new.Replace($anchorStock, '...' + $vN + '?{anchor:' + $nZ + '?()=>' + $bN + '[' + $nI + ']:' + $bN + '}:{}')
        $new = $new.Replace(',ref:' + $bN + $jsxTail.Replace('\', ''), ',ref:' + $nZ + '?' + $nL + '=>' + $bN + '[' + $nI + ']=' + $nL + ':' + $bN + '}:{},children:[')
        $new = $new.Replace($tipStock, '@TIP@')
        $new = $oName + '.map((' + $eN + ',' + $nI + ',' + $nL + ',' + $nZ + '=' + $oName + '[' + $nI + '+1])=>' + $new + ')'
        $room = $region.Length - ($new.Length - 5)           # 5 = '@TIP@'
        $tip = $null
        foreach ($tp in $tipShorts) { if ($tp.Length -le $room) { $tip = $tp; break } }
        if ($null -eq $tip) { return @{ State = 'UNKNOWN'; Detail = "no room for the added code ($room chars left for the tooltip)"; Edits = @() } }
        $new = $new.Replace('@TIP@', $tip)
        $new = $new + (' ' * ($region.Length - $new.Length))
        if ($new.Length -ne $region.Length) { return @{ State = 'UNKNOWN'; Detail = 'scriptbuttons edit would change length'; Edits = @() } }
        $edits = @()
        if ($direction -eq 'patched') {
            $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $bodyStart); Old = $region; New = $new; Chunk = $chunk; ChunkText = $text }
        }
        return @{ State = 'ORIGINAL'; Detail = "$short, one split button (tooltip -> '$tip' when patched)"; Edits = $edits }
    }
    # PATCHED: rebuild stock text and require the round trip to match
    $oP = $c['O'].Value; $iP = $c['Ix'].Value; $lP = $c['L'].Value; $zP = $c['Z'].Value
    $head = $oP + '.map((' + $eN + ',' + $iP + ',' + $lP + ',' + $zP + '=' + $oP + '[' + $iP + '+1])=>'
    if (-not $region.StartsWith($head, [StringComparison]::Ordinal)) { return @{ State = 'UNKNOWN'; Detail = 'patched head shape mismatch'; Edits = @() } }
    $inner = $region.Substring($head.Length).TrimEnd(' ')
    if (-not $inner.EndsWith(')')) { return @{ State = 'UNKNOWN'; Detail = 'patched tail shape mismatch'; Edits = @() } }
    $inner = $inner.Substring(0, $inner.Length - 1)
    if ($c['B2'].Value -ne $bN) { return @{ State = 'UNKNOWN'; Detail = 'patched ref shape mismatch'; Edits = @() } }
    $refP = ',ref:' + $zP + '?' + $lP + '=>' + $bN + '[' + $iP + ']=' + $lP + ':' + $bN + '}:{},children:['
    if (([regex]::Matches($inner, [regex]::Escape($refP))).Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = 'patched ref not found once'; Edits = @() } }
    $inner = $inner.Replace($refP, ',ref:' + $bN + '}:{},children:[')
    $anchorP = '...' + $vN + '?{anchor:' + $zP + '?()=>' + $bN + '[' + $iP + ']:' + $bN + '}:{}'
    if (([regex]::Matches($inner, [regex]::Escape($anchorP))).Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = 'patched anchor not found once'; Edits = @() } }
    $inner = $inner.Replace($anchorP, '...' + $vN + '?{anchor:' + $bN + '}:{}')
    $cmP = [regex]::Match($inner, ('\(0,\$\.jsxs\)\(@I@,\{open:(?<C>@I@)\.scripts==' + [regex]::Escape($iP) + '\+1,onOpenChange:(?<e>@I@)=>@I@\(\{presentation:@I@,scripts:\k<e>&&' + [regex]::Escape($iP) + '\+1,imports:!1\}\),children:\[').Replace('@I@', $I))
    if (-not $cmP.Success) { return @{ State = 'UNKNOWN'; Detail = 'patched chevron state shape mismatch'; Edits = @() } }
    $inner = $inner.Replace($cmP.Value, $cmP.Value.Replace('.scripts==' + $iP + '+1,', '.scripts,').Replace('&&' + $iP + '+1,imports', ',imports'))
    $tipFound = $null
    foreach ($tp in $tipShorts) { if (([regex]::Matches($inner, [regex]::Escape($tp))).Count -eq 1) { $tipFound = $tp; break } }
    if ($null -eq $tipFound) { return @{ State = 'UNKNOWN'; Detail = 'patched tooltip not recognized'; Edits = @() } }
    $inner = $inner.Replace($tipFound, $tipStock)
    $oldRegion = $inner
    $edits = @()
    if ($direction -eq 'stock') {
        if ($oldRegion.Length -gt $region.Length) { return @{ State = 'UNKNOWN'; Detail = 'stock rebuild is longer than the patched region'; Edits = @() } }
        $oldRegion = $oldRegion + (' ' * ($region.Length - $oldRegion.Length))
        $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $bodyStart); Old = $region; New = $oldRegion; Chunk = $chunk; ChunkText = $text }
    }
    return @{ State = 'PATCHED'; Detail = "$short, one button per script (tooltip '$tipFound')"; Edits = $edits }
}

$script:SbTplStock = @'
~e~?(0,~$~.jsxs)(~v~,{role:`group`,"aria-label":`Project scripts`,..._?{className:~ow~,ref:~y~}:{},children:[(0,~$~.jsxs)(~yo~,{children:[(0,~$~.jsxs)(~Un~,{render:(0,~$~.jsx)(~dw~,{size:`xs`,variant:~_~?`ghost`:`outline`,part:`primary`,panel:~_~,className:~_~?void 0:`w-7 sm:w-6 @3xl/header-actions:w-auto!`,"aria-label":`Run ${~e~.name}`,"data-toolbar-control":``,"aria-disabled":!~l~||void 0,onClick:()=>~l~?.(~e~)}),children:[(0,~$~.jsx)(~zb~,{icon:~e~~%~,..._?{className:~nw~}:{}}),(0,~$~.jsx)(`span`,{className:~Oa~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~_~&&~Oa~(`not-sr-only ml-0 truncate`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~e~.name})]}),(0,~$~.jsx)(~qe~,{side:`top`,children:~l~?`Run ${~e~.name}`:`Pair this client again with permission to run terminal commands.`})]}),~_~?(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~lw~}):(0,~$~.jsx)(~hw~,{className:`hidden @3xl/header-actions:block`}),(0,~$~.jsxs)(~Pe~,{open:~S~.scripts,onOpenChange:~e~=>~C~({presentation:~m~,scripts:~e~,imports:!1}),children:[(0,~$~.jsx)(~ii~,{render:(0,~$~.jsx)(~dw~,{size:~_~?`sm`:`icon-xs`,variant:~_~?`ghost`:`outline`,part:`secondary`,panel:~_~,"aria-label":`Script actions`}),children:(0,~$~.jsx)(~te~,{className:~_~?~rw~:`size-4`})}),(0,~$~.jsx)(~Qi~,{align:`end`,..._?{anchor:~y~}:{},className:~_~?`w-(--anchor-width)`:void 0,children:~M~})]})]}):~o~.length>0||~n~.length>0?~_~?(0,~$~.jsxs)(`div`,{role:`group`,"aria-label":`Project actions`,className:~ow~,ref:~y~,children:[(0,~$~.jsxs)(~dw~,{size:`sm`,variant:`ghost`,part:`primary`,"aria-label":`Project actions`,onClick:()=>~C~({presentation:~m~,scripts:!1,imports:!0}),children:[(0,~$~.jsx)(~Ae~,{className:~nw~}),(0,~$~.jsx)(`span`,{className:~Oa~(`min-w-0 truncate`,~XC~),children:`Actions`})]}),(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~lw~}),(0,~$~.jsxs)(~Pe~,{highlightItemOnHover:!1,open:~S~.imports,onOpenChange:~e~=>~C~({presentation:~m~,scripts:!1,imports:~e~}),children:[(0,~$~.jsx)(~ii~,{render:(0,~$~.jsx)(~dw~,{size:`sm`,variant:`ghost`,part:`secondary`,"aria-label":`Choose project action`}),children:(0,~$~.jsx)(~te~,{className:~rw~})}),(0,~$~.jsx)(~Qi~,{align:`end`,anchor:~y~,className:`w-(--anchor-width)`,children:~M~})]})]}):(0,~$~.jsxs)(~Pe~,{highlightItemOnHover:!1,open:~S~.imports,onOpenChange:~e~=>~C~({presentation:~m~,scripts:!1,imports:~e~}),children:[(0,~$~.jsxs)(~ii~,{render:(0,~$~.jsx)(~Yt~,{size:`xs`,variant:`outline`,"aria-label":`Project actions`}),children:[(0,~$~.jsx)(~Ae~,{className:`size-3.5`}),(0,~$~.jsx)(`span`,{className:`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,children:`Actions`}),(0,~$~.jsx)(~te~,{className:`size-3.5`})]}),(0,~$~.jsx)(~Qi~,{align:`end`,children:~M~})]}):(0,~$~.jsxs)(~yo~,{children:[(0,~$~.jsxs)(~Un~,{render:(0,~$~.jsx)(~dw~,{size:`xs`,variant:~_~?`ghost`:`outline`,part:`row`,panel:~_~,className:~_~?void 0:`w-7 sm:w-6 @3xl/header-actions:w-auto!`,"aria-label":~_~?`Add project script`:`Add action`,"data-toolbar-control":``,onClick:~r~}),children:[(0,~$~.jsx)(~xe~,{className:`size-3.5`}),(0,~$~.jsx)(`span`,{className:~Oa~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~_~&&~Oa~(`not-sr-only ml-0.5`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~_~?`Add project script`:`Add action`})]}),(0,~$~.jsx)(~qe~,{side:`top`,children:~_~?`Add project script`:`Add action`})]})
'@
$script:SbTplV3 = @'
[~e~&&~o~.map((~e~,~I~,~L~,~Z~=~o~[~I~+1])=>(0,~$~.jsxs)(~v~,{role:`group`,"aria-label":`Project scripts`,className:~ow~,ref:~Z~?~L~=>~y~[~I~]=~L~:~y~,draggable:!0,onDragStart:~L~=>~L~.dataTransfer.setData(`t3sb`,~I~),onDragOver:~L~=>~L~.preventDefault(),onDrop:~L~=>{~L~=~L~.dataTransfer.getData(`t3sb`);let ~Z~=[...~o~];~L~&&~L~!=~I~&&(~Z~.splice(~I~,0,...~Z~.splice(~L~,1)),~d~(~Z~))},children:[(0,~$~.jsxs)(~yo~,{children:[(0,~$~.jsxs)(~Un~,{render:(0,~$~.jsx)(~dw~,{size:`xs`,variant:`ghost`,part:`primary`,panel:~_~,"aria-label":`Run ${~e~.name}`,"data-toolbar-control":``,"aria-disabled":!~l~||void 0,onClick:()=>~l~?.(~e~)}),children:[(0,~$~.jsx)(~zb~,{icon:~e~~%~,..._?{className:~nw~}:{}}),(0,~$~.jsx)(`span`,{className:~Oa~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~_~&&~Oa~(`not-sr-only ml-0 truncate`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~e~.name})]}),(0,~$~.jsx)(~qe~,{side:`top`,children:~l~?`Run ${~e~.name}`:`Re-pair.`})]}),~_~?(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~lw~}):!~hw~,(0,~$~.jsxs)(~Pe~,{open:~S~.scripts==~I~+1,onOpenChange:~e~=>~C~({presentation:~m~,scripts:~e~&&~I~+1,imports:!1}),children:[(0,~$~.jsx)(~ii~,{render:(0,~$~.jsx)(~dw~,{size:`sm`,variant:`ghost`,part:`secondary`,panel:~_~,"aria-label":`Script actions`}),children:(0,~$~.jsx)(~te~,{className:~rw~})}),(0,~$~.jsx)(~Qi~,{align:`end`,anchor:~Z~?()=>~y~[~I~]:~y~,className:`w-(--anchor-width)`,children:[(0,~$~.jsxs)(~_a~,{onClick:()=>~s~(~e~),children:[(0,~$~.jsx)(~T_~,{className:`size-4`}),`Edit`]}),(0,~$~.jsxs)(~_a~,{variant:`destructive`,onClick:()=>~pd~()?.dialogs.confirm(`Remove ${~e~.name}?`,{variant:`destructive`}).then(~n~=>~n~&&~t~[~#~](~e~.id)),children:[(0,~$~.jsx)(~ke~,{className:`size-4`}),`Remove`]}),~f~]})]})]})),!~e~&&(~o~.length>0||~n~.length>0)?(0,~$~.jsxs)(`div`,{role:`group`,"aria-label":`Project actions`,className:~ow~,ref:~y~,children:[(0,~$~.jsxs)(~dw~,{size:`sm`,variant:`ghost`,part:`primary`,"aria-label":`Project actions`,onClick:()=>~C~({presentation:~m~,scripts:!1,imports:!0}),children:[(0,~$~.jsx)(~Ae~,{className:~nw~}),(0,~$~.jsx)(`span`,{className:~Oa~(`min-w-0 truncate`,~XC~),children:`Actions`})]}),(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~lw~}),(0,~$~.jsxs)(~Pe~,{highlightItemOnHover:!1,open:~S~.imports,onOpenChange:~e~=>~C~({presentation:~m~,scripts:!1,imports:~e~}),children:[(0,~$~.jsx)(~ii~,{render:(0,~$~.jsx)(~dw~,{size:`sm`,variant:`ghost`,part:`secondary`,"aria-label":`Choose project action`}),children:(0,~$~.jsx)(~te~,{className:~rw~})}),(0,~$~.jsx)(~Qi~,{align:`end`,anchor:~y~,className:`w-(--anchor-width)`,children:~M~})]}),!~Yt~]}):(0,~$~.jsxs)(~yo~,{children:[(0,~$~.jsxs)(~Un~,{render:(0,~$~.jsx)(~dw~,{size:`xs`,variant:`ghost`,part:`row`,panel:~_~,"aria-label":`Add project script`,"data-toolbar-control":``,onClick:~r~}),children:[(0,~$~.jsx)(~xe~,{className:`size-3.5`}),(0,~$~.jsx)(`span`,{className:~Oa~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~_~&&~Oa~(`not-sr-only ml-0.5`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:`Add project script`})]}),(0,~$~.jsx)(~qe~,{side:`top`,children:`Add project script`})]})]
'@
# Pass 30/31 (2026-11-09, 2026-11-10): one button per script; each button's menu holds Edit and a
# red Remove (asks first) plus the t3.json import list when there is one. "Add project script" is its
# own button under the last script. Pass 31: a script button can be dragged above or below another
# (saved through T3's own project-script save, as an Edit would be), and a script that opens a page
# reuses its browser tab instead of opening a second one. Three parts, one patch name:
#   dock  - the run-button/actions/add block, rewritten from a template; ~name~ marks a minified name
#           read from the chunk, so a rebuild with new names still matches. Name tables are
#           case-sensitive (m and M differ). The older form (2026-10-24) is recognised by
#           Resolve-ScriptButtonsV1 and upgraded in place. The toolbar-only variants are dropped.
#   order - updateProjectScript also takes a whole reordered list (one line in the save hook).
#   tab   - opening a preview URL first looks for the tab this thread already opened for that URL.
# Same length everywhere: shorter error messages and a dropped source-map comment pay for the code.
function ConvertTo-SbRegex([string]$tpl, [hashtable]$groups) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('(?<![\w$])')
    $seen = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($p in [regex]::Split($tpl, '(~[^~]+~)')) {
        if ($p.Length -gt 2 -and $p.StartsWith('~') -and $p.EndsWith('~')) {
            $n = $p.Substring(1, $p.Length - 2)
            if (-not $groups.ContainsKey($n)) { $groups[$n] = 'g' + $groups.Count }
            $g = $groups[$n]
            $pat = if ($n -eq '#') { '\d+' } elseif ($n -eq '%') { '\.icon|/\*i\*/' } else { $I }
            if ($seen.ContainsKey($n)) { [void]$sb.Append('\k<' + $g + '>') }
            else { $seen[$n] = $true; [void]$sb.Append('(?<' + $g + '>' + $pat + ')') }
        } elseif ($p.Length) { [void]$sb.Append([regex]::Escape($p)) }
    }
    return $sb.ToString()
}
function Format-SbTemplate([string]$tpl, [hashtable]$names) {
    $out = New-Object System.Text.StringBuilder
    foreach ($p in [regex]::Split($tpl, '(~[^~]+~)')) {
        if ($p.Length -gt 2 -and $p.StartsWith('~') -and $p.EndsWith('~')) {
            $n = $p.Substring(1, $p.Length - 2)
            if (-not $names.ContainsKey($n)) { throw "scriptbuttons: no value for ~$n~" }
            [void]$out.Append($names[$n])
        } else { [void]$out.Append($p) }
    }
    return $out.ToString()
}
function Get-SbNames([System.Text.RegularExpressions.Match]$m, [hashtable]$groups) {
    $names = [hashtable]::new([StringComparer]::Ordinal)
    foreach ($k in $groups.Keys) { if ($m.Groups[$groups[$k]].Success) { $names[$k] = $m.Groups[$groups[$k]].Value } }
    return $names
}
$script:SbTplStock4 = @'
~e~?(0,~$~.jsxs)(~C~,{role:`group`,"aria-label":~b~(`Project scripts`),...~S~?{className:~Xb~,ref:~w~}:{},children:[(0,~$~.jsxs)(~Fn~,{children:[(0,~$~.jsxs)(~on~,{render:(0,~$~.jsx)(~Vb~,{size:`xs`,variant:~S~?`ghost`:`outline`,part:`primary`,panel:~S~,className:~S~?void 0:`w-7 sm:w-6 @3xl/header-actions:w-auto!`,"aria-label":~b~(`Run {name}`,{name:~e~.name}),"data-toolbar-control":``,"aria-disabled":!~u~||void 0,onClick:()=>~u~?.(~e~)}),children:[(0,~$~.jsx)(~rw~,{icon:~e~~%~,...~S~?{className:~eS~}:{}}),(0,~$~.jsx)(`span`,{className:~kr~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~S~&&~kr~(`not-sr-only ml-0 truncate`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~e~.name})]}),(0,~$~.jsx)(~Xt~,{side:`top`,children:~u~?~b~(`Run {name}`,{name:~e~.name}):~b~(`Pair this client again with permission to run terminal commands.`)})]}),~S~?(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~wb~}):(0,~$~.jsx)(~aD~,{className:`hidden @3xl/header-actions:block`}),(0,~$~.jsxs)(~Ut~,{open:~O~.scripts,onOpenChange:~e~=>~k~({presentation:~g~,scripts:~e~,imports:!1}),children:[(0,~$~.jsxs)(~Fn~,{children:[(0,~$~.jsx)(~on~,{render:(0,~$~.jsx)(~Ke~,{render:(0,~$~.jsx)(~Vb~,{size:~S~?`sm`:`icon-xs`,variant:~S~?`ghost`:`outline`,part:`secondary`,panel:~S~,"aria-label":~b~(`Script actions`),"data-toolbar-control":``})}),children:(0,~$~.jsx)(~fa~,{className:~S~?~sb~:`size-4`})}),(0,~$~.jsx)(~Xt~,{side:`top`,children:(0,~$~.jsx)(~X~,{children:`Script actions`})})]}),(0,~$~.jsx)(~Jr~,{align:`end`,...~S~?{anchor:~w~}:{},className:~S~?`w-(--anchor-width)`:void 0,children:~L~})]})]}):~o~.length>0||~r~.length>0?~S~?(0,~$~.jsxs)(`div`,{role:`group`,"aria-label":~b~(`Project actions`),className:~Xb~,ref:~w~,children:[(0,~$~.jsxs)(~Vb~,{size:`sm`,variant:`ghost`,part:`primary`,"aria-label":~b~(`Project actions`),onClick:()=>~k~({presentation:~g~,scripts:!1,imports:!0}),children:[(0,~$~.jsx)(~$a~,{className:~eS~}),(0,~$~.jsx)(`span`,{className:~kr~(`min-w-0 truncate`,~nb~),children:(0,~$~.jsx)(~X~,{context:`project actions menu`,children:`Actions`})})]}),(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~wb~}),(0,~$~.jsxs)(~Ut~,{highlightItemOnHover:!1,open:~O~.imports,onOpenChange:~e~=>~k~({presentation:~g~,scripts:!1,imports:~e~}),children:[(0,~$~.jsx)(~Ke~,{render:(0,~$~.jsx)(~Vb~,{size:`sm`,variant:`ghost`,part:`secondary`,"aria-label":~b~(`Choose project action`)}),children:(0,~$~.jsx)(~fa~,{className:~sb~})}),(0,~$~.jsx)(~Jr~,{align:`end`,anchor:~w~,className:`w-(--anchor-width)`,children:~L~})]})]}):(0,~$~.jsxs)(~Ut~,{highlightItemOnHover:!1,open:~O~.imports,onOpenChange:~e~=>~k~({presentation:~g~,scripts:!1,imports:~e~}),children:[(0,~$~.jsxs)(~Ke~,{render:(0,~$~.jsx)(~Rt~,{size:`xs`,variant:`outline`,"aria-label":~b~(`Project actions`)}),children:[(0,~$~.jsx)(~$a~,{className:`size-3.5`}),(0,~$~.jsx)(`span`,{className:`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,children:(0,~$~.jsx)(~X~,{context:`project actions menu`,children:`Actions`})}),(0,~$~.jsx)(~fa~,{className:`size-3.5`})]}),(0,~$~.jsx)(~Jr~,{align:`end`,children:~L~})]}):(0,~$~.jsxs)(~Fn~,{children:[(0,~$~.jsxs)(~on~,{render:(0,~$~.jsx)(~Vb~,{size:`xs`,variant:~S~?`ghost`:`outline`,part:`row`,panel:~S~,className:~S~?void 0:`w-7 sm:w-6 @3xl/header-actions:w-auto!`,"aria-label":~b~(~S~?`Add project script`:`Add action`),"data-toolbar-control":``,onClick:~c~}),children:[(0,~$~.jsx)(~Ga~,{className:`size-3.5`}),(0,~$~.jsx)(`span`,{className:~kr~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~S~&&~kr~(`not-sr-only ml-0.5`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~b~(~S~?`Add project script`:`Add action`)})]}),(0,~$~.jsx)(~Xt~,{side:`top`,children:~b~(~S~?`Add project script`:`Add action`)})]})
'@
$script:SbTplV4 = @'
[~e~&&~o~.map((~e~,~I1~,~L1~,~Z1~=~o~[~I1~+1])=>(0,~$~.jsxs)(~C~,{role:`group`,"aria-label":~b~(`Project scripts`),className:~Xb~,ref:~Z1~?~L1~=>~w~[~I1~]=~L1~:~w~,draggable:!0,onDragStart:~L1~=>~L1~.dataTransfer.setData(`t3sb`,~I1~),onDragOver:~L1~=>~L1~.preventDefault(),onDrop:~L1~=>{~L1~=~L1~.dataTransfer.getData(`t3sb`);let ~Z1~=[...~o~];~L1~&&~L1~!=~I1~&&(~Z1~.splice(~I1~,0,...~Z1~.splice(~L1~,1)),~p~(~Z1~))},children:[(0,~$~.jsxs)(~Fn~,{children:[(0,~$~.jsxs)(~on~,{render:(0,~$~.jsx)(~Vb~,{size:`xs`,variant:`ghost`,part:`primary`,panel:~S~,"aria-label":~b~(`Run {name}`,{name:~e~.name}),"data-toolbar-control":``,"aria-disabled":!~u~||void 0,onClick:()=>~u~?.(~e~)}),children:[(0,~$~.jsx)(~rw~,{icon:~e~~%~,...~S~?{className:~eS~}:{}}),(0,~$~.jsx)(`span`,{className:~kr~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~S~&&~kr~(`not-sr-only ml-0 truncate`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~e~.name})]}),(0,~$~.jsx)(~Xt~,{side:`top`,children:~u~?`Run ${~e~.name}`:`Re-pair.`})]}),~S~?(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~wb~}):!~aD~,(0,~$~.jsxs)(~Ut~,{open:~O~.scripts==~I1~+1,onOpenChange:~e~=>~k~({presentation:~g~,scripts:~e~&&~I1~+1,imports:!1}),children:[(0,~$~.jsx)(~Ke~,{render:(0,~$~.jsx)(~Vb~,{size:`sm`,variant:`ghost`,part:`secondary`,panel:~S~,"aria-label":~b~(`Script actions`)}),children:(0,~$~.jsx)(~fa~,{className:~sb~})}),(0,~$~.jsx)(~Jr~,{align:`end`,anchor:~Z1~?()=>~w~[~I1~]:~w~,className:`w-(--anchor-width)`,children:[(0,~$~.jsxs)(~Qr~,{onClick:()=>{~k~({presentation:~g~,scripts:!1,imports:!1}),~j~(~XC~(~e~,~T~))},children:[(0,~$~.jsx)(~Nx~,{className:`size-4`}),`Edit`]}),(0,~$~.jsxs)(~Qr~,{variant:`destructive`,onClick:()=>~Nu~()?.dialogs.confirm(`Remove ${~e~.name}?`,{variant:`destructive`}).then(~r~=>~r~&&~t~[~#~](~e~.id)),children:[(0,~$~.jsx)(~Qa~,{className:`size-4`}),`Remove`]}),~n~]})]})]})),!~e~&&(~o~.length>0||~r~.length>0)?(0,~$~.jsxs)(`div`,{role:`group`,"aria-label":~b~(`Project actions`),className:~Xb~,ref:~w~,children:[(0,~$~.jsxs)(~Vb~,{size:`sm`,variant:`ghost`,part:`primary`,"aria-label":~b~(`Project actions`),onClick:()=>~k~({presentation:~g~,scripts:!1,imports:!0}),children:[(0,~$~.jsx)(~$a~,{className:~eS~}),(0,~$~.jsx)(`span`,{className:~kr~(`min-w-0 truncate`,~nb~),children:(0,~$~.jsx)(~X~,{context:`project actions menu`,children:`Actions`})})]}),(0,~$~.jsx)(`span`,{"aria-hidden":`true`,className:~wb~}),(0,~$~.jsxs)(~Ut~,{highlightItemOnHover:!1,open:~O~.imports,onOpenChange:~e~=>~k~({presentation:~g~,scripts:!1,imports:~e~}),children:[(0,~$~.jsx)(~Ke~,{render:(0,~$~.jsx)(~Vb~,{size:`sm`,variant:`ghost`,part:`secondary`,"aria-label":~b~(`Choose project action`)}),children:(0,~$~.jsx)(~fa~,{className:~sb~})}),(0,~$~.jsx)(~Jr~,{align:`end`,anchor:~w~,className:`w-(--anchor-width)`,children:~L~})]}),!~Rt~]}):(0,~$~.jsxs)(~Fn~,{children:[(0,~$~.jsxs)(~on~,{render:(0,~$~.jsx)(~Vb~,{size:`xs`,variant:`ghost`,part:`row`,panel:~S~,"aria-label":~b~(`Add project script`),"data-toolbar-control":``,onClick:~c~}),children:[(0,~$~.jsx)(~Ga~,{className:`size-3.5`}),(0,~$~.jsx)(`span`,{className:~kr~(`sr-only @3xl/header-actions:not-sr-only @3xl/header-actions:ml-0.5`,~S~&&~kr~(`not-sr-only ml-0.5`,`[text-box:trim-both_cap_alphabetic] overflow-x-clip overflow-y-visible`)),children:~b~(`Add project script`)})]}),(0,~$~.jsx)(~Xt~,{side:`top`,children:~b~(`Add project script`)})]})]
'@
# 2026-11-22 build (0.1.12-nightly.20261122): the same dock with its labels wrapped for translation and
# the menu pieces under new names. Same idea as the older templates: ~name~ is a minified name read from
# the chunk; the new menu needs a few names the stock block never touches (save list, edit request,
# confirm box, delete callback slot), read from the surrounding component. Returns $null when this shape
# is not in the build, so the older logic still runs.
function Resolve-SbDockV4([string]$direction) {
    $bq = [string]$bt
    $anchorRe = ('role:' + $bq + 'group' + $bq + ',"aria-label":(?:@I@\()?' + $bq + 'Project scripts' + $bq).Replace('@I@', $I)
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (-not $t.Contains('Project scripts')) { continue }
        $am = [regex]::Match($t, $anchorRe)
        if ($am.Success) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t; At = $am.Index } }
    }
    if ($hits.Count -ne 1) { return $null }
    $chunk = $hits[0].Chunk; $text = $hits[0].Text
    $winStart = [Math]::Max(0, $hits[0].At - 400)
    $win = $text.Substring($winStart, [Math]::Min(6000, $text.Length - $winStart))
    $gS = [hashtable]::new([StringComparer]::Ordinal); $reS = ConvertTo-SbRegex $script:SbTplStock4 $gS
    $gP = [hashtable]::new([StringComparer]::Ordinal); $reP = (ConvertTo-SbRegex $script:SbTplV4 $gP) + '(?<pad> *)'
    $mp = [regex]::Matches($win, $reP)
    $ms = [regex]::Matches($win, $reS)
    if ($mp.Count -eq 0 -and $ms.Count -eq 0) { return $null }
    if ($mp.Count + $ms.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "script dock (2026-11-22 shape) matched $($mp.Count) patched and $($ms.Count) stock times"; Edits = @() } }
    if ($mp.Count -eq 1) {
        $m = $mp[0]
        $names = Get-SbNames $m $gP
        $stockText = Format-SbTemplate $script:SbTplStock4 $names
        if ($stockText.Length -gt $m.Length) { return @{ State = 'UNKNOWN'; Detail = 'stock rebuild is longer than the patched block'; Edits = @() } }
        $edits = @()
        if ($direction -eq 'stock') {
            $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $winStart + $m.Index); Old = $m.Value; New = $stockText + (' ' * ($m.Length - $stockText.Length)); Chunk = $chunk; ChunkText = $text }
        }
        return @{ State = 'PATCHED'; Detail = "dock: one button per script, Edit/Remove menus, drag order"; Edits = $edits }
    }
    $m = $ms[0]
    $names = Get-SbNames $m $gS
    $detail = 'dock: one split button'
    if ($direction -ne 'patched') { return @{ State = 'ORIGINAL'; Detail = $detail; Edits = @() } }
    $startRel = $winStart + $m.Index
    $fnStart = $text.LastIndexOf('function ', $startRel, [StringComparison]::Ordinal)
    if ($fnStart -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'script dock component start not found'; Edits = @() } }
    $comp = $text.Substring($fnStart, [Math]::Min($text.Length - $fnStart, ($startRel - $fnStart) + $m.Length + 2500))
    $J = [regex]::Escape($names['$'])
    $upd = [regex]::Match($comp, 'onUpdateScript:(?<u>@I@),onDeleteScript:'.Replace('@I@', $I))
    $del = [regex]::Match($comp, 'onDeleteScript:(?<d>@I@)\}='.Replace('@I@', $I))
    $slot = [regex]::Match($comp, ('let (?<O>@I@);(?<t>@I@)\[(?<n>\d+)\]===(?<d>@I@)\?\k<O>=\k<t>\[\d+\]:\(\k<O>=(?<q>@I@)=>void \k<d>\(\k<q>\),\k<t>\[\k<n>\]=\k<d>').Replace('@I@', $I))
    if (-not $upd.Success -or -not $del.Success -or -not $slot.Success -or $slot.Groups['d'].Value -ne $del.Groups['d'].Value -or -not $comp.Contains('onDelete:' + $slot.Groups['O'].Value + ',')) { return @{ State = 'UNKNOWN'; Detail = 'update/delete callbacks not found'; Edits = @() } }
    $eh = [regex]::Match($comp, ('let (?<h>@I@)=(?<q>@I@)=>\{@I@\.current\+=1,@I@\?\.\(\),(?<k>@I@)\(\{presentation:(?<g>@I@),scripts:!1,imports:!1\}\),(?<j>@I@)\((?<XC>@I@)\(\k<q>,(?<T>@I@)\)\)\}').Replace('@I@', $I))
    if (-not $eh.Success -or $eh.Groups['k'].Value -cne $names['k'] -or $eh.Groups['g'].Value -cne $names['g']) { return @{ State = 'UNKNOWN'; Detail = 'edit handler not found'; Edits = @() } }
    $eb = [regex]::Match($comp, ('"aria-label":@I@\(' + $bq + 'Edit \{name\}' + $bq + ',\{name:(?<q>@I@)\.name\}\),onPointerDown:@I@,onClick:(?<w>@I@)=>\{\k<w>\.preventDefault\(\),\k<w>\.stopPropagation\(\),(?<h>@I@)\(\k<q>\)\},children:\(0,' + $J + '\.jsx\)\((?<pen>@I@),\{className:' + $bq + 'size-3\.5' + $bq + '\}\)').Replace('@I@', $I))
    if (-not $eb.Success -or $eb.Groups['h'].Value -cne $eh.Groups['h'].Value) { return @{ State = 'UNKNOWN'; Detail = 'edit button not found'; Edits = @() } }
    $item = [regex]::Match($comp, ('\(0,' + $J + '\.jsxs\)\((?<a>@I@),\{density:@I@,onClick:' + [regex]::Escape($names['c']) + ',children:\[').Replace('@I@', $I))
    if (-not $item.Success) { return @{ State = 'UNKNOWN'; Detail = 'menu item component not found'; Edits = @() } }
    $frag = [regex]::Match($comp, ('\((?<j>@I@)=\(0,' + $J + '\.jsxs\)\(' + $J + '\.Fragment,\{children:\[@I@,(?<f>@I@),@I@\]\}\)[^;]*;let ' + [regex]::Escape($names['L']) + '=\k<j>[;,]').Replace('@I@', $I))
    if (-not $frag.Success) { return @{ State = 'UNKNOWN'; Detail = 't3.json import list not found'; Edits = @() } }
    $bin = [regex]::Match($text, ('"aria-label":@I@\(' + $bq + 'Delete side chat' + $bq + '\),[^}]{0,120}children:\(0,' + $J + '\.jsx\)\((?<ke>@I@),\{\}\)\}').Replace('@I@', $I))
    if (-not $bin.Success) { return @{ State = 'UNKNOWN'; Detail = 'bin icon not found'; Edits = @() } }
    $dlg = [regex]::Matches($text, '(?<![\w$.])(?<pd>@I@)\(\)\?\.dialogs\.confirm\('.Replace('@I@', $I))
    if ($dlg.Count -lt 1) { return @{ State = 'UNKNOWN'; Detail = 'confirm dialog helper not found'; Edits = @() } }
    $names['t'] = $slot.Groups['t'].Value; $names['#'] = $slot.Groups['n'].Value
    $names['p'] = $upd.Groups['u'].Value
    $names['j'] = $eh.Groups['j'].Value; $names['XC'] = $eh.Groups['XC'].Value; $names['T'] = $eh.Groups['T'].Value
    $names['Nx'] = $eb.Groups['pen'].Value; $names['Qr'] = $item.Groups['a'].Value; $names['n'] = $frag.Groups['f'].Value
    $names['Qa'] = $bin.Groups['ke'].Value; $names['Nu'] = $dlg[0].Groups['pd'].Value
    $taken = @($names.Values)
    $free = @()
    foreach ($ch in [char[]]'ILZQWKJHGFDSAPMNBXUTRYqjkzxwp') {
        $cs = [string]$ch
        if ($taken -cnotcontains $cs -and -not [regex]::IsMatch($m.Value, '(?<![\w$])' + [regex]::Escape($cs) + '(?![\w$])')) { $free += $cs }
        if ($free.Count -eq 3) { break }
    }
    if ($free.Count -lt 3) { return @{ State = 'UNKNOWN'; Detail = 'no free names for the map callback'; Edits = @() } }
    $names['I1'] = $free[0]; $names['L1'] = $free[1]; $names['Z1'] = $free[2]
    $new = Format-SbTemplate $script:SbTplV4 $names
    if ($new.Length -gt $m.Length) { return @{ State = 'UNKNOWN'; Detail = "new script menu is $($new.Length - $m.Length) chars too long"; Edits = @() } }
    $new += (' ' * ($m.Length - $new.Length))
    $back = [regex]::Matches($new, $reP)
    if ($back.Count -ne 1 -or $back[0].Length -ne $new.Length -or (Format-SbTemplate $script:SbTplStock4 (Get-SbNames $back[0] $gP)) -cne $m.Value) { return @{ State = 'UNKNOWN'; Detail = 'new script menu does not round-trip to the stock text'; Edits = @() } }
    $edits = @(@{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $startRel); Old = $m.Value; New = $new; Chunk = $chunk; ChunkText = $text })
    return @{ State = 'ORIGINAL'; Detail = $detail; Edits = $edits }
}
function Resolve-SbDock([string]$direction) {
    $v4 = Resolve-SbDockV4 $direction
    if ($null -ne $v4) { return $v4 }
    $bq = [string]$bt
    $anchor = 'role:' + $bq + 'group' + $bq + ',"aria-label":' + $bq + 'Project scripts' + $bq
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if ($t.Contains($anchor)) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "project-scripts anchor found in $($hits.Count) chunks (expected 1)"; Edits = @() } }
    $chunk = $hits[0].Chunk; $text = $hits[0].Text
    $short = "chunk $(Split-Path $chunk.Path -Leaf)"
    $at = $text.IndexOf($anchor, [StringComparison]::Ordinal)
    $winStart = [Math]::Max(0, $at - 400)
    $win = $text.Substring($winStart, [Math]::Min(5000, $text.Length - $winStart))
    $gS = [hashtable]::new([StringComparer]::Ordinal); $reS = ConvertTo-SbRegex $script:SbTplStock $gS
    $gV = [hashtable]::new([StringComparer]::Ordinal); $reV = (ConvertTo-SbRegex $script:SbTplV3 $gV) + '(?<pad> *)'
    # new form already in place
    $mv = [regex]::Matches($win, $reV)
    if ($mv.Count -gt 1) { return @{ State = 'UNKNOWN'; Detail = "new script menu matched $($mv.Count) times"; Edits = @() } }
    if ($mv.Count -eq 1) {
        $m = $mv[0]
        $names = Get-SbNames $m $gV
        $stockText = Format-SbTemplate $script:SbTplStock $names
        if ($stockText.Length -gt $m.Length) { return @{ State = 'UNKNOWN'; Detail = 'stock rebuild is longer than the patched block'; Edits = @() } }
        $edits = @()
        if ($direction -eq 'stock') {
            $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $winStart + $m.Index); Old = $m.Value; New = $stockText + (' ' * ($m.Length - $stockText.Length)); Chunk = $chunk; ChunkText = $text }
        }
        return @{ State = 'PATCHED'; Detail = "dock: one button per script, Edit/Remove menus, drag order"; Edits = $edits }
    }
    # older per-script form: rebuild its stock text in memory, then go on as if stock
    $work = $text; $workWinStart = $winStart; $extra = 0; $from = 'stock'
    $v1 = Resolve-ScriptButtonsV1 'stock'
    if ($v1.State -eq 'PATCHED') {
        if ($direction -eq 'stock') { return $v1 }
        $e1 = @($v1.Edits)[0]
        $rel = [int]($e1.Off - $dataOffset - $chunk.Offset)
        $stockPart = $e1.New.TrimEnd(' ')
        $extra = $e1.Old.Length - $stockPart.Length
        $work = $text.Substring(0, $rel) + $stockPart + $text.Substring($rel + $e1.Old.Length)
        $from = 'older per-script form'
    } elseif ($v1.State -ne 'ORIGINAL') {
        return @{ State = 'UNKNOWN'; Detail = $v1.Detail; Edits = @() }
    }
    $wwin = $work.Substring($workWinStart, [Math]::Min(5000, $work.Length - $workWinStart))
    $ms = [regex]::Matches($wwin, $reS)
    if ($ms.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "stock script dock matched $($ms.Count) times (expected 1)"; Edits = @() } }
    $m = $ms[0]
    $names = Get-SbNames $m $gS
    $startRel = $workWinStart + $m.Index
    $spanLen = $m.Length + $extra
    $state = 'ORIGINAL'
    $detail = if ($from -eq 'stock') { "dock: one split button" } else { "dock: older per-script menus (upgrade pending)" }
    if ($direction -ne 'patched') { return @{ State = $state; Detail = $detail; Edits = @() } }
    # names the new block needs that the stock block does not use
    $esc = { param($s) [regex]::Escape($s) }
    $fnStart = $work.LastIndexOf('function ', $startRel, [StringComparison]::Ordinal)
    if ($fnStart -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'script dock component start not found'; Edits = @() } }
    $comp = $work.Substring($fnStart, [Math]::Min($work.Length - $fnStart, ($startRel - $fnStart) + $m.Length + 2500))
    $J = & $esc $names['$']
    $upd = [regex]::Match($comp, ('onUpdateScript:(?<u>@I@),onDeleteScript:').Replace('@I@', $I))
    if (-not $upd.Success) { return @{ State = 'UNKNOWN'; Detail = 'update callback not found'; Edits = @() } }
    $del = [regex]::Match($comp, ('onDeleteScript:(?<d>@I@)\}=').Replace('@I@', $I))
    $slot = [regex]::Match($comp, ('let (?<O>@I@);(?<t>@I@)\[(?<n>\d+)\]===(?<d>@I@)\?\k<O>=\k<t>\[\d+\]:\(\k<O>=(?<q>@I@)=>void \k<d>\(\k<q>\),\k<t>\[\k<n>\]=\k<d>').Replace('@I@', $I))
    if (-not $del.Success -or -not $slot.Success -or $slot.Groups['d'].Value -ne $del.Groups['d'].Value -or -not $comp.Contains('onDelete:' + $slot.Groups['O'].Value + ',')) { return @{ State = 'UNKNOWN'; Detail = 'delete callback cache slot not found'; Edits = @() } }
    $edit = [regex]::Match($comp, ('"aria-label":' + $bq + 'Edit \$\{(?<q>@I@)\.name\}' + $bq + ',onPointerDown:@I@,onClick:(?<w>@I@)=>\{\k<w>\.preventDefault\(\),\k<w>\.stopPropagation\(\),(?<s>@I@)\(\k<q>\)\},children:\(0,' + $J + '\.jsx\)\((?<pen>@I@),\{className:' + $bq + 'size-3\.5' + $bq + '\}\)').Replace('@I@', $I))
    if (-not $edit.Success) { return @{ State = 'UNKNOWN'; Detail = 'edit handler not found'; Edits = @() } }
    $item = [regex]::Match($comp, ('\(0,' + $J + '\.jsxs\)\((?<a>@I@),\{density:@I@,onClick:' + (& $esc $names['r']) + ',children:\[').Replace('@I@', $I))
    if (-not $item.Success) { return @{ State = 'UNKNOWN'; Detail = 'menu item component not found'; Edits = @() } }
    $frag = [regex]::Match($comp, ('\((?<j>@I@)=\(0,' + $J + '\.jsxs\)\(' + $J + '\.Fragment,\{children:\[@I@,(?<f>@I@),@I@\]\}\)[^;]*;let ' + (& $esc $names['M']) + '=\k<j>[;,]').Replace('@I@', $I))
    if (-not $frag.Success) { return @{ State = 'UNKNOWN'; Detail = 't3.json import list not found'; Edits = @() } }
    $bin = [regex]::Match($text, ('\((?<v>@I@)=\(0,' + $J + '\.jsx\)\((?<ke>@I@),\{\}\),.{0,160}?"aria-label":' + $bq + 'Delete side chat' + $bq + ',[^}]{0,80}children:\k<v>\}').Replace('@I@', $I))
    if (-not $bin.Success) { return @{ State = 'UNKNOWN'; Detail = 'bin icon not found'; Edits = @() } }
    $dlg = [regex]::Matches($text, ('(?<![\w$.])(?<pd>@I@)\(\)\?\.dialogs\.confirm\(').Replace('@I@', $I))
    if ($dlg.Count -lt 1) { return @{ State = 'UNKNOWN'; Detail = 'confirm dialog helper not found'; Edits = @() } }
    $names['t'] = $slot.Groups['t'].Value; $names['#'] = $slot.Groups['n'].Value
    $names['s'] = $edit.Groups['s'].Value; $names['T_'] = $edit.Groups['pen'].Value
    $names['_a'] = $item.Groups['a'].Value; $names['f'] = $frag.Groups['f'].Value
    $names['ke'] = $bin.Groups['ke'].Value; $names['pd'] = $dlg[0].Groups['pd'].Value
    $names['d'] = $upd.Groups['u'].Value
    # three names for the map callback that nothing in or around the block uses
    $taken = @($names.Values)
    $free = @()
    foreach ($ch in [char[]]'ILZQWKJHGFDSAPMNBXUTRYqjkzxwp') {
        $cs = [string]$ch
        if ($taken -cnotcontains $cs -and -not [regex]::IsMatch($m.Value, '(?<![\w$])' + [regex]::Escape($cs) + '(?![\w$])')) { $free += $cs }
        if ($free.Count -eq 3) { break }
    }
    if ($free.Count -lt 3) { return @{ State = 'UNKNOWN'; Detail = 'no free names for the map callback'; Edits = @() } }
    $names['I'] = $free[0]; $names['L'] = $free[1]; $names['Z'] = $free[2]
    $new = Format-SbTemplate $script:SbTplV3 $names
    if ($new.Length -gt $spanLen) { return @{ State = 'UNKNOWN'; Detail = "new script menu is $($new.Length - $spanLen) chars too long"; Edits = @() } }
    $new += (' ' * ($spanLen - $new.Length))
    $old = $text.Substring($startRel, $spanLen)
    $edits = @(@{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $startRel); Old = $old; New = $new; Chunk = $chunk; ChunkText = $text })
    return @{ State = $state; Detail = $detail; Edits = $edits }
}
function Get-SbFreeNames([string]$text, [int]$count) {
    $free = @()
    foreach ($ch in [char[]]'KFGHJQWXYZNOPU') {
        $cs = [string]$ch
        if (-not [regex]::IsMatch($text, '(?<![\w$])' + [regex]::Escape($cs) + '(?![\w$])')) { $free += $cs }
        if ($free.Count -eq $count) { break }
    }
    return ,$free
}
# order: updateProjectScript(list) saves a reordered list through the same settings write as Edit.
function Resolve-SbOrder([string]$direction) {
    $r1 = Resolve-SbOrderV1 $direction
    if ($null -ne $r1) { return $r1 }
    return Resolve-SbOrderV2 $direction
}
# 2026-11 build: the save hook's messages are the same, the edit handler now calls the shared save
# function with the project folder and the previous list too. The old messages are still in the
# language catalog chunk, so chunks are counted by whole-pattern matches, not by a text search.
function Resolve-SbOrderV2([string]$direction) {
    $bq = [string]$bt
    $s1 = $bq + 'The script was deleted, but its keyboard shortcut could not be removed because permission changed.' + $bq
    $s2 = $bq + 'The script was saved, but this connection can no longer change keyboard shortcuts.' + $bq
    $p1 = $bq + 'Deleted; shortcut not removed.' + $bq
    $p2 = $bq + 'Saved; shortcut not changed.' + $bq
    $mid = '(?<mid>[\s\S]{0,4000}?=async\((?<a>@I@),@I@\)=>\{if\(!(?<r>@I@)\)return @I@\(void 0\);)'
    $tail = '(?=let @I@=@I@\.find\(@I@=>@I@\.id===\k<a>\);if\(!@I@\)return @I@\(@I@\(Error\(@I@\(@I@\(' + $bq + 'Script not found\.' + $bq + '\)\)\)\)\);[\s\S]{0,300}?return (?<m>@I@)\(\{projectId:\k<r>\.id,projectCwd:(?<cw>[^,{}]{1,40}),previousScripts:(?<p>@I@),nextScripts:)'
    $reS = ([regex]::Escape($s1 + ':' + $s2) + $mid + $tail).Replace('@I@', $I)
    $reP = ([regex]::Escape($p1 + ':' + $p2) + $mid + 'if\(\k<a>\.map\)return (?<m2>@I@)\(\{projectId:\k<r>\.id,projectCwd:(?<cw2>[^,{}]{1,40}),previousScripts:(?<p2>@I@),nextScripts:\k<a>\}\);(?<pad> *)' + $tail).Replace('@I@', $I)
    $hits = @()
    foreach ($c in @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (-not ($t.Contains($s1) -or $t.Contains($p1))) { continue }
        $ms = [regex]::Matches($t, $reS); $mp = [regex]::Matches($t, $reP)
        if ($ms.Count + $mp.Count -gt 0) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t; S = $ms; P = $mp } }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "order: script save hook found in $($hits.Count) chunks (expected 1)"; Edits = @() } }
    $chunk = $hits[0].Chunk; $text = $hits[0].Text
    if ($hits[0].S.Count + $hits[0].P.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "order: save hook matched $($hits[0].S.Count) stock / $($hits[0].P.Count) patched"; Edits = @() } }
    if ($hits[0].P.Count -eq 1) {
        $m = $hits[0].P[0]; $g = $m.Groups
        if ($g['m2'].Value -cne $g['m'].Value -or $g['cw2'].Value -cne $g['cw'].Value -or $g['p2'].Value -cne $g['p'].Value) { return @{ State = 'UNKNOWN'; Detail = 'order: list save call differs from the edit save call'; Edits = @() } }
        $edits = @()
        if ($direction -eq 'stock') {
            $new = $s1 + ':' + $s2 + $g['mid'].Value
            if ($new.Length -ne $m.Length) { return @{ State = 'UNKNOWN'; Detail = 'order: stock rebuild length differs'; Edits = @() } }
            $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $m.Index); Old = $m.Value; New = $new; Chunk = $chunk; ChunkText = $text }
        }
        return @{ State = 'PATCHED'; Detail = 'order: list save on'; Edits = $edits }
    }
    $m = $hits[0].S[0]; $g = $m.Groups
    if ($direction -ne 'patched') { return @{ State = 'ORIGINAL'; Detail = 'order: stock save hook'; Edits = @() } }
    $a = $g['a'].Value
    $new = $p1 + ':' + $p2 + $g['mid'].Value + 'if(' + $a + '.map)return ' + $g['m'].Value + '({projectId:' + $g['r'].Value + '.id,projectCwd:' + $g['cw'].Value + ',previousScripts:' + $g['p'].Value + ',nextScripts:' + $a + '});'
    if ($new.Length -gt $m.Length) { return @{ State = 'UNKNOWN'; Detail = "order: edit is $($new.Length - $m.Length) chars too long"; Edits = @() } }
    $new += ' ' * ($m.Length - $new.Length)
    return @{ State = 'ORIGINAL'; Detail = 'order: stock save hook'; Edits = @(@{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $m.Index); Old = $m.Value; New = $new; Chunk = $chunk; ChunkText = $text }) }
}
function Resolve-SbOrderV1([string]$direction) {
    $bq = [string]$bt
    $msgS = $bq + 'The script was deleted, but its keyboard shortcut could not be removed because permission changed.' + $bq
    $msgP = $bq + 'Deleted; shortcut not removed.' + $bq
    $mid = '(?<mid>[\s\S]{0,4000}?=async\((?<a>@I@),@I@\)=>\{if\(!(?<r>@I@)\)return @I@\(void 0\);)'
    $tail = '(?=let @I@=@I@\.find\(@I@=>@I@\.id===\k<a>\);if\(!@I@\)return @I@\(@I@\(Error\(' + $bq + 'Script not found\.' + $bq + '\)\)\);[\s\S]{0,300}?return (?<m>@I@)\(\{projectId:\k<r>\.id,)'
    $reS = ([regex]::Escape($msgS) + $mid + $tail).Replace('@I@', $I)
    $reP = ([regex]::Escape($msgP) + $mid + 'if\(\k<a>\.map\)return (?<m2>@I@)\(\{projectId:\k<r>\.id,nextScripts:\k<a>\}\);(?<pad> *)' + $tail).Replace('@I@', $I)
    $hits = @()
    foreach ($c in @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (($t.Contains($msgS) -or $t.Contains($msgP)) -and ([regex]::IsMatch($t, $reS) -or [regex]::IsMatch($t, $reP))) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hits.Count -eq 0) { return $null }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "order: script save hook found in $($hits.Count) chunks (expected 1)"; Edits = @() } }
    $chunk = $hits[0].Chunk; $text = $hits[0].Text
    $mp = [regex]::Matches($text, $reP)
    $ms = [regex]::Matches($text, $reS)
    if ($mp.Count + $ms.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "order: save hook matched $($ms.Count) stock / $($mp.Count) patched"; Edits = @() } }
    if ($mp.Count -eq 1) {
        $m = $mp[0]
        if ($m.Groups['m2'].Value -cne $m.Groups['m'].Value) { return @{ State = 'UNKNOWN'; Detail = 'order: save call name differs'; Edits = @() } }
        $edits = @()
        if ($direction -eq 'stock') {
            $new = $msgS + $m.Groups['mid'].Value
            if ($new.Length -ne $m.Length) { return @{ State = 'UNKNOWN'; Detail = 'order: stock rebuild length differs'; Edits = @() } }
            $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $m.Index); Old = $m.Value; New = $new; Chunk = $chunk; ChunkText = $text }
        }
        return @{ State = 'PATCHED'; Detail = 'order: list save on'; Edits = $edits }
    }
    $m = $ms[0]
    if ($direction -ne 'patched') { return @{ State = 'ORIGINAL'; Detail = 'order: stock save hook'; Edits = @() } }
    $a = $m.Groups['a'].Value
    $new = $msgP + $m.Groups['mid'].Value + 'if(' + $a + '.map)return ' + $m.Groups['m'].Value + '({projectId:' + $m.Groups['r'].Value + '.id,nextScripts:' + $a + '});'
    if ($new.Length -gt $m.Length) { return @{ State = 'UNKNOWN'; Detail = "order: edit is $($new.Length - $m.Length) chars too long"; Edits = @() } }
    $new += ' ' * ($m.Length - $new.Length)
    return @{ State = 'ORIGINAL'; Detail = 'order: stock save hook'; Edits = @(@{ Kind = 'region'; Patch = 'scriptbuttons'; Off = [int64]($dataOffset + $chunk.Offset + $m.Index); Old = $m.Value; New = $new; Chunk = $chunk; ChunkText = $text }) }
}
# tab: a preview URL opened again in the same thread goes back to the tab it opened before
# (tab id kept in localStorage under t3tab<threadId><url>; a closed tab is simply opened anew).
function Resolve-SbTab([string]$direction) {
    $bq = [string]$bt
    $q = { param($s) [regex]::Escape($bq + $s + $bq) }
    $txtS = @('Saved browser settings could not be loaded.', 'The integrated browser is unavailable in this runtime.', 'The environment returned an invalid asset URL.')
    $txtP = @('Browser settings unreadable.', 'No integrated browser here.', 'Invalid asset URL.')
    $A = '(?<A>[\s\S]{0,300}?let (?<a>@I@)=@I@\((?<e>@I@)\.threadRef\)[\s\S]{0,300}?=(?<u>@I@)\(\k<a>\)\.activeTabId,[\s\S]{0,200}?,)'
    $B = '(?<B>[\s\S]{0,400}?\);return @I@\(\k<b>,(?<tt>@I@)=>\{)'
    $reS = ((& $q $txtS[0]) + $A + '(?<b>@I@)=await \k<e>\.openPreview\(' + $B + '(?<C>[\s\S]{0,900}?)' + (& $q $txtS[1]) + '(?<D>[\s\S]{0,900}?)' + (& $q $txtS[2]) + '(?<E>[\s\S]{0,400}?)(?<map>\n//# sourceMappingURL=[^\n]*\n?)?\z').Replace('@I@', $I)
    $reP = ((& $q $txtP[0]) + $A + '(?<K>@I@)=' + $bq + 't3tab\$\{\k<a>\.threadId\+\k<e>\.url\}' + $bq + ',(?<F>@I@)=\k<u>\(\k<a>\)\.sessions\[localStorage\[\k<K>\]\],(?<b>@I@)=\k<F>\?\{_tag:' + $bq + 'Success' + $bq + ',value:\k<F>\}:await \k<e>\.openPreview\(' + $B + 'localStorage\[\k<K>\]=\k<tt>\.tabId,(?<C>[\s\S]{0,900}?)' + (& $q $txtP[1]) + '(?<D>[\s\S]{0,900}?)' + (& $q $txtP[2]) + '(?<E>[\s\S]{0,400}?)(?<pad> *)\z').Replace('@I@', $I)
    $hits = @()
    foreach ($c in @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })) {
        $t = Get-ChunkText $c.Offset $c.Size
        if ($t.Contains('BrowserSettingsReadError') -and $t.Contains('.openPreview(')) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t } }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "tab: preview opener found in $($hits.Count) chunks (expected 1)"; Edits = @() } }
    $chunk = $hits[0].Chunk; $text = $hits[0].Text
    $from = $text.IndexOf($bq + $txtS[0] + $bq, [StringComparison]::Ordinal)
    if ($from -lt 0) { $from = $text.IndexOf($bq + $txtP[0] + $bq, [StringComparison]::Ordinal) }
    if ($from -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'tab: settings message not found'; Edits = @() } }
    $tail = $text.Substring($from)
    $mp = [regex]::Match($tail, $reP)
    $ms = [regex]::Match($tail, $reS)
    $abs = [int64]($dataOffset + $chunk.Offset + $from)
    if ($mp.Success -and $mp.Index -eq 0) {
        $g = $mp.Groups
        $edits = @()
        if ($direction -eq 'stock') {
            $new = $bq + $txtS[0] + $bq + $g['A'].Value + $g['b'].Value + '=await ' + $g['e'].Value + '.openPreview(' + $g['B'].Value + $g['C'].Value + $bq + $txtS[1] + $bq + $g['D'].Value + $bq + $txtS[2] + $bq + $g['E'].Value
            $gap = $mp.Length - $new.Length
            if ($gap -gt 0) {
                $map = "`n//# sourceMappingURL=" + (Split-Path $chunk.Path -Leaf) + '.map'
                if ($map.Length -eq $gap) { $new += $map } elseif ($map.Length + 1 -eq $gap) { $new += $map + "`n" } else { return @{ State = 'UNKNOWN'; Detail = 'tab: source-map line cannot be rebuilt'; Edits = @() } }
            } elseif ($gap -lt 0) { return @{ State = 'UNKNOWN'; Detail = 'tab: stock rebuild is longer'; Edits = @() } }
            $edits += @{ Kind = 'region'; Patch = 'scriptbuttons'; Off = $abs; Old = $mp.Value; New = $new; Chunk = $chunk; ChunkText = $text }
        }
        return @{ State = 'PATCHED'; Detail = 'tab: one tab per page'; Edits = $edits }
    }
    if (-not ($ms.Success -and $ms.Index -eq 0)) { return @{ State = 'UNKNOWN'; Detail = 'tab: preview opener shape not recognised'; Edits = @() } }
    if ($direction -ne 'patched') { return @{ State = 'ORIGINAL'; Detail = 'tab: new tab per click'; Edits = @() } }
    $g = $ms.Groups
    $fr = Get-SbFreeNames $text 2
    if ($fr.Count -lt 2) { return @{ State = 'UNKNOWN'; Detail = 'tab: no free names'; Edits = @() } }
    $K = $fr[0]; $F = $fr[1]; $a = $g['a'].Value; $ev = $g['e'].Value
    $new = $bq + $txtP[0] + $bq + $g['A'].Value + $K + '=' + $bq + 't3tab${' + $a + '.threadId+' + $ev + '.url}' + $bq + ',' + $F + '=' + $g['u'].Value + '(' + $a + ').sessions[localStorage[' + $K + ']],' + $g['b'].Value + '=' + $F + '?{_tag:' + $bq + 'Success' + $bq + ',value:' + $F + '}:await ' + $ev + '.openPreview(' + $g['B'].Value + 'localStorage[' + $K + ']=' + $g['tt'].Value + '.tabId,' + $g['C'].Value + $bq + $txtP[1] + $bq + $g['D'].Value + $bq + $txtP[2] + $bq + $g['E'].Value
    if ($new.Length -gt $ms.Length) { return @{ State = 'UNKNOWN'; Detail = "tab: edit is $($new.Length - $ms.Length) chars too long"; Edits = @() } }
    $new += ' ' * ($ms.Length - $new.Length)
    return @{ State = 'ORIGINAL'; Detail = 'tab: new tab per click'; Edits = @(@{ Kind = 'region'; Patch = 'scriptbuttons'; Off = $abs; Old = $ms.Value; New = $new; Chunk = $chunk; ChunkText = $text }) }
}
# One patch, three parts. Stock direction reverts every part that is patched; otherwise the patch
# counts as PATCHED only when all three parts are, and -Apply finishes whichever parts are missing.
function Resolve-ScriptButtons([string]$direction) {
    $parts = @((Resolve-SbDock $direction), (Resolve-SbOrder $direction), (Resolve-SbTab $direction))
    $detail = ($parts | ForEach-Object { $_.Detail }) -join '; '
    if (@($parts | Where-Object { $_.State -eq 'UNKNOWN' }).Count) { return @{ State = 'UNKNOWN'; Detail = $detail; Edits = @() } }
    $edits = @(); foreach ($p in $parts) { $edits += @($p.Edits) }
    $on = @($parts | Where-Object { $_.State -eq 'PATCHED' }).Count
    if ($direction -eq 'stock') { $state = if ($on) { 'PATCHED' } else { 'ORIGINAL' } }
    else {
        $state = if ($on -eq $parts.Count) { 'PATCHED' } else { 'ORIGINAL' }
        if ($on -gt 0 -and $on -lt $parts.Count) { $detail = "partly patched: $detail" }
    }
    return @{ State = $state; Detail = $detail; Edits = $edits }
}

# --- patch 9: browser pages open in dark mode by default --------------------------
# The built-in browser's default appearance setting is system|light|dark and ships as
# `system`. This changes the shipped default to `dark` (same length: two trailing
# spaces) so a fresh or reset settings file also gives dark pages. The user's own
# value in ~/.t3/userdata/client-settings.json is set to "dark" separately.
function Resolve-BrowserDark([string]$direction) {
    $bq = [string]$bt
    $reStock = ('(?<=,)(?<n>@I@)=' + $bq + 'system' + $bq + '(?=,)').Replace('@I@', $I)
    $rePatch = ('(?<=,)(?<n>@I@)=' + $bq + 'dark' + $bq + '  (?=,)').Replace('@I@', $I)
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (-not $t.Contains('browserDefaultAppearance:')) { continue }
        foreach ($pair in @(@('ORIGINAL', $reStock), @('PATCHED', $rePatch))) {
            foreach ($m in [regex]::Matches($t, $pair[1])) {
                # the default is the declaration right after the enum literal [`system`,`light`,`dark`]
                $before = $t.Substring([Math]::Max(0, $m.Index - 40), [Math]::Min(40, $m.Index))
                if (-not $before.Contains($bq + 'system' + $bq + ',' + $bq + 'light' + $bq + ',' + $bq + 'dark' + $bq + ']')) { continue }
                $n = $m.Groups['n'].Value
                # and the settings schema uses it as the browserDefaultAppearance default
                # (the wrapper's minified name changes between builds: D(n), k(n), ...)
                if (-not [regex]::IsMatch($t, 'browserDefaultAppearance:[^,]{0,40}\(' + [regex]::Escape($n) + '\)')) { continue }
                $hits += [pscustomobject]@{ Chunk = $c; Text = $t; M = $m; State = $pair[0] }
            }
        }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "default-appearance declaration matched $($hits.Count) times (expected 1)"; Edits = @() } }
    $h = $hits[0]
    $edits = @()
    $stockText = $h.M.Groups['n'].Value + '=' + $bq + 'system' + $bq
    $patchText = $h.M.Groups['n'].Value + '=' + $bq + 'dark' + $bq + '  '
    if ($stockText.Length -ne $patchText.Length) { return @{ State = 'UNKNOWN'; Detail = 'browserdark edit would change length'; Edits = @() } }
    if ($h.State -eq 'ORIGINAL' -and $direction -eq 'patched') { $old = $stockText; $new = $patchText }
    elseif ($h.State -eq 'PATCHED' -and $direction -eq 'stock') { $old = $patchText; $new = $stockText }
    else { $old = $null }
    if ($null -ne $old) { $edits += @{ Kind = 'region'; Patch = 'browserdark'; Off = [int64]($dataOffset + $h.Chunk.Offset + $h.M.Index); Old = $old; New = $new; Chunk = $h.Chunk; ChunkText = $h.Text } }
    return @{ State = $h.State; Detail = "default appearance $($h.State) in $(Split-Path $h.Chunk.Path -Leaf)"; Edits = $edits }
}

# --- seconds on the sidebar working timer ------------------------------------------
# The sidebar row timer ("Working 23m") re-renders every second (1 s clock store) but
# its formatter drops seconds after the first minute. The call site gets a suffix
# that adds " 27s" when the page flag self.T3S is true; local-settings-ui.js sets that
# flag from the Settings switch (localStorage t3local.sidebarSeconds), so the switch
# works live with no reload. Under 60 s the stock text already shows seconds.
# The extra bytes come from the chunk's source-map trailer, which becomes spaces;
# -Revert restores the exact bytes.
function Resolve-SidebarSeconds([string]$direction) {
    $bq = [string]$bt
    # two recognised shapes: older builds (clock read with no arguments, one-slot cache) and the
    # 2026-11 build (clock read takes the environment id, two-slot cache keyed on locale and elapsed)
    $reOld = '(?<n>@I@)=@I@\(\)-@I@\.startedMs,(?<r>@I@);@I@\[0\]===\k<n>\?\k<r>=@I@\[1\]:\(\k<r>=@I@\(\k<n>\)'
    $reNew = '(?<n>@I@)=@I@\([^()]{1,60}\)-@I@\.startedMs,(?<r>@I@);@I@\[0\]!==@I@\|\|@I@\[1\]!==\k<n>\?\(\k<r>=@I@\(\k<n>,@I@\)'
    $reCall = ('(?<pre>' + $reOld + '|' + $reNew + ')').Replace('@I@', $I)
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (-not $t.Contains('.startedMs,')) { continue }
        foreach ($m in [regex]::Matches($t, $reCall)) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t; M = $m } }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "sidebar timer call matched $($hits.Count) times (expected 1)"; Edits = @() } }
    $h = $hits[0]
    $text = $h.Text
    $n = $h.M.Groups['n'].Value
    $ins = '+(self.T3S&&' + $n + '>=6e4?' + $bq + ' ${' + $n + '/1e3%60|0}s' + $bq + ':' + $bq + $bq + ')'
    $name = Split-Path $h.Chunk.Path -Leaf
    $tail = $nl + '//# sourceMappingURL=' + $name + '.map'
    $at = $h.M.Index + $h.M.Length
    $patched = ($text.Length -ge $at + $ins.Length) -and ($text.Substring($at, $ins.Length) -ceq $ins)
    $short = "timer call in $name"
    if ($patched) {
        if (-not $text.EndsWith(' ')) { return @{ State = 'UNKNOWN'; Detail = "$short is patched but the trailer pad is missing"; Edits = @() } }
        $edits = @()
        if ($direction -eq 'stock') {
            $restored = $text.Remove($at, $ins.Length).TrimEnd(' ') + $tail
            if ($restored.Length -ne $text.Length) { return @{ State = 'UNKNOWN'; Detail = "$short revert would change length ($($restored.Length) vs $($text.Length))"; Edits = @() } }
            $edits = @(@{ Kind = 'chunk'; Patch = 'sidebarsecs'; Chunk = $h.Chunk; ChunkText = $text; NewChunkText = $restored })
        }
        return @{ State = 'PATCHED'; Detail = "$short, seconds suffix"; Edits = $edits }
    }
    if (-not $text.EndsWith($tail)) { return @{ State = 'UNKNOWN'; Detail = "$short is stock but the chunk has no source-map trailer to make room"; Edits = @() } }
    if ($ins.Length -gt $tail.Length) { return @{ State = 'UNKNOWN'; Detail = "seconds suffix ($($ins.Length)) is longer than the trailer ($($tail.Length))"; Edits = @() } }
    $edits = @()
    if ($direction -eq 'patched') {
        $newText = $text.Substring(0, $text.Length - $tail.Length).Insert($at, $ins)
        $newText = $newText + (' ' * ($text.Length - $newText.Length))
        $edits = @(@{ Kind = 'chunk'; Patch = 'sidebarsecs'; Chunk = $h.Chunk; ChunkText = $text; NewChunkText = $newText })
    }
    return @{ State = 'ORIGINAL'; Detail = "$short, minutes only (stock)"; Edits = $edits }
}

# --- every account in the thread popover's usage limits ---------------------------
# The popover reads only the selected instance's own account. Behind CLIProxyAPI that
# account has no limits ("Unavailable"), while the proxy usage source has one account
# per auth file. The patch lists every account with readable limits for the instance's
# driver (the same list the Usage page uses), each row prefixed with the first 5
# characters of its email, or the name set for that email in local-patches.json
# accountNames (the loader passes it to the page as self.T3N). Rows are keyed by label so the accounts' windows don't
# collide. When no account has limits, the first account's reason shows. The bytes come from the Unavailable tooltip wrapper, the heading id and a
# redundant tone:null.
# 2026-11 build (T3 Code 0.1.12-nightly.20261122): the popover's limits come from one function in the
# chat chunk (CW) that reads the instance's account out of the usage store; when that account has no
# limits T3 now pools the other accounts into averaged rows itself. The patch hands the account list
# to self.T3A (defined in ~/.t3/local-settings-ui.js), which returns one row per readable account,
# labelled like the older patch (name from accountNames, else the first 5 characters of the email), or
# nothing, in which case T3's own result is used. Only the `let o=...;` statement changes, and the
# bytes come from spaces after it. Returns $null when this build's shape is not there.
function Resolve-UsageAccountsV2([string]$direction) {
    $bq = [string]$bt
    $tail = ';@PAD@if(!@o@)return null;let @s@=@K@(@a@,@r@);return @Q@@W@(@o@)===null||@s@.length===0?{kind:' + $bq + 'instance' + $bq + ',limits:@o@}:@T@(@a@.driver,@t@,@n@,@s@,@i@)??{kind:' + $bq + 'instance' + $bq + ',limits:@o@}}'
    $stockT = 'let @o@=@H@(@a@.instanceId,@n@,@r@,@i@,@t@)?.accounts.find(e=>e.instanceId===@a@.instanceId)?.limits??@a@.usageLimits' + $tail.Replace('@PAD@', '').Replace('@Q@', '')
    $patchT = 'let @o@=self.T3A?.(@H@(@a@.instanceId,@n@,@r@,@i@,@t@)?.accounts,@W@,@a@.instanceId)??@a@.usageLimits' + $tail.Replace('@Q@', '@o@.t3a||')
    $toRe = {
        param($tmpl)
        $sb = New-Object System.Text.StringBuilder
        $seen = [hashtable]::new([StringComparer]::Ordinal)
        foreach ($p in [regex]::Split($tmpl, '(@[A-Za-z]+@)')) {
            if ($p.Length -gt 2 -and $p.StartsWith('@') -and $p.EndsWith('@')) {
                $k = $p.Substring(1, $p.Length - 2)
                $pat = if ($k -ceq 'PAD') { ' *' } else { $I }
                if ($seen.ContainsKey($k)) { [void]$sb.Append('\k<' + $k + '>') }
                else { $seen[$k] = $true; [void]$sb.Append('(?<' + $k + '>' + $pat + ')') }
            } elseif ($p.Length) { [void]$sb.Append([regex]::Escape($p)) }
        }
        return $sb.ToString()
    }
    $fill = {
        param($tmpl, $m, $pad)
        $s = $tmpl.Replace('@PAD@', $pad)
        foreach ($k in 'o', 'H', 'a', 'n', 'r', 'i', 't', 's', 'K', 'W', 'T') { $s = $s.Replace('@' + $k + '@', $m.Groups[$k].Value) }
        return $s
    }
    $reS = & $toRe $stockT
    $reP = & $toRe $patchT
    $hits = @()
    foreach ($c in @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (-not $t.Contains($bq + 'Usage limits' + $bq) -or -not $t.Contains('.usageLimits;')) { continue }
        foreach ($pair in @(@('ORIGINAL', $reS), @('PATCHED', $reP))) {
            foreach ($m in [regex]::Matches($t, $pair[1])) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t; M = $m; State = $pair[0] } }
        }
    }
    if ($hits.Count -eq 0) { return $null }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "popover usage function matched $($hits.Count) times (expected 1)"; Edits = @() } }
    $h = $hits[0]; $m = $h.M
    $stockText = & $fill $stockT $m ''
    $patchBare = & $fill $patchT $m ''
    if ($patchBare.Length -gt $stockText.Length) { return @{ State = 'UNKNOWN'; Detail = "usageaccounts edit is $($patchBare.Length - $stockText.Length) chars too long"; Edits = @() } }
    $patchText = & $fill $patchT $m (' ' * ($stockText.Length - $patchBare.Length))
    if ($m.Length -ne $stockText.Length) { return @{ State = 'UNKNOWN'; Detail = "usageaccounts block length $($m.Length) differs from stock $($stockText.Length)"; Edits = @() } }
    if ($h.State -eq 'ORIGINAL' -and $direction -eq 'patched') { $old = $stockText; $new = $patchText }
    elseif ($h.State -eq 'PATCHED' -and $direction -eq 'stock') { $old = $patchText; $new = $stockText }
    else { $old = $null }
    $edits = @()
    if ($null -ne $old) {
        if ($old -cne $m.Value) { return @{ State = 'UNKNOWN'; Detail = 'usageaccounts rebuild does not match the live text'; Edits = @() } }
        $edits += @{ Kind = 'region'; Patch = 'usageaccounts'; Off = [int64]($dataOffset + $h.Chunk.Offset + $m.Index); Old = $old; New = $new; Chunk = $h.Chunk; ChunkText = $h.Text }
    }
    $what = if ($h.State -eq 'PATCHED') { 'all accounts (self.T3A)' } else { 'own account / pooled (stock)' }
    return @{ State = $h.State; Detail = "popover usage in $(Split-Path $h.Chunk.Path -Leaf), $what"; Edits = $edits }
}
function Resolve-UsageAccounts([string]$direction) {
    $v2 = Resolve-UsageAccountsV2 $direction
    if ($null -ne $v2) { return $v2 }
    $stockT ='t=(n===null?null:@H@(n,r,i,e))?.accounts.find(e=>e.instanceId===n)?.limits??r.find(e=>e.instanceId===n)?.usageLimits;if(!t){f=null;break bb0}let p=@W@(t);o=@D@,l=`thread-details-usage-heading`,u=`Usage limits`,d=!1,s=`grid grid-cols-[auto_minmax(3rem,1fr)_auto] gap-x-3 text-xs`,c=p?(0,@J@.jsx)(@U@,{label:`Limits`,fill:null,tone:null,value:`Unavailable`,tooltip:(0,@J@.jsx)(`span`,{className:`text-foreground`,children:p})}):t.windows.map(t=>(0,@J@.jsx)(@C@,{window:t,now:e},t.id))'
    $patchT = 'B=@H@(n,r,i,e)?.accounts??[],A=B.filter(e=>!@W@(e.limits)),t=A[0]?{windows:A.flatMap(a=>a.limits.windows.map(w=>({...w,label:(self.T3N?.[a.email]??(a.email??a.id).slice(0,5))+` `+w.label})))}:B[0]?.limits;   if(!t){f=null;break bb0}let p=@W@(t);o=@D@,l=`ul`,u=`Usage limits`,d=!1,s=`grid grid-cols-[auto_minmax(3rem,1fr)_auto] gap-x-3 text-xs`,c=p?(0,@J@.jsx)(@U@,{label:`Limits`,fill:null,value:`Unavailable`,tooltip:p}):t.windows.map(t=>(0,@J@.jsx)(@C@,{window:t,now:e},t.label))'
    $oldT   = 'A=(@H@(n,r,i,e)?.accounts??[]).filter(e=>!@W@(e.limits)),t=A[0]?{windows:A.flatMap(a=>a.limits.windows.map(w=>({...w,label:(a.email??a.id).slice(0,5)+` `+w.label})))}:r.find(e=>e.instanceId===n)?.usageLimits;if(!t){f=null;break bb0}let p=@W@(t);o=@D@,l=`ul`,u=`Usage limits`,d=!1,s=`grid grid-cols-[auto_minmax(3rem,1fr)_auto] gap-x-3 text-xs`,c=p?(0,@J@.jsx)(@U@,{label:`Limits`,fill:null,value:`Unavailable`,tooltip:p}):t.windows.map(t=>(0,@J@.jsx)(@C@,{window:t,now:e},t.label))'
    $keys = 'H', 'W', 'D', 'J', 'U', 'C'
    $toRe = {
        param($tmpl)
        $re = [regex]::Escape($tmpl)
        foreach ($k in $keys) {
            $tok = '@' + $k + '@'
            $at = $re.IndexOf($tok)
            if ($at -lt 0) { continue }
            $re = $re.Remove($at, $tok.Length).Insert($at, "(?<$k>$I)").Replace($tok, "\k<$k>")
        }
        return $re
    }
    $fill = {
        param($tmpl, $m)
        $s = $tmpl
        foreach ($k in $keys) { $s = $s.Replace('@' + $k + '@', $m.Groups[$k].Value) }
        return $s
    }
    $bq = [string]$bt
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $hits = @()
    foreach ($c in $cands) {
        $t = Get-ChunkText $c.Offset $c.Size
        if (-not $t.Contains($bq + 'Usage limits' + $bq)) { continue }
        foreach ($pair in @(@('ORIGINAL', (& $toRe $stockT)), @('PATCHED', (& $toRe $patchT)), @('OLD', (& $toRe $oldT)))) {
            foreach ($m in [regex]::Matches($t, $pair[1])) { $hits += [pscustomobject]@{ Chunk = $c; Text = $t; M = $m; State = $pair[0] } }
        }
    }
    if ($hits.Count -ne 1) { return @{ State = 'UNKNOWN'; Detail = "popover usage block matched $($hits.Count) times (expected 1)"; Edits = @() } }
    $h = $hits[0]
    $stockText = & $fill $stockT $h.M
    $patchText = & $fill $patchT $h.M
    if ($h.State -eq 'OLD') {
        # the first version (email prefixes) is live: upgrade it, or put stock back
        $oldText = & $fill $oldT $h.M
        $edits = @()
        $new = if ($direction -eq 'patched') { $patchText } elseif ($direction -eq 'stock') { $stockText } else { $null }
        if ($null -ne $new) { $edits += @{ Kind = 'region'; Patch = 'usageaccounts'; Off = [int64]($dataOffset + $h.Chunk.Offset + $h.M.Index); Old = $oldText; New = $new; Chunk = $h.Chunk; ChunkText = $h.Text } }
        return @{ State = 'ORIGINAL'; Detail = "popover usage in $(Split-Path $h.Chunk.Path -Leaf), first version (email prefixes)"; Edits = $edits }
    }
    if ($stockText.Length -ne $patchText.Length) { return @{ State = 'UNKNOWN'; Detail = "usageaccounts edit would change length ($($stockText.Length) vs $($patchText.Length))"; Edits = @() } }
    if ($h.State -eq 'ORIGINAL' -and $direction -eq 'patched') { $old = $stockText; $new = $patchText }
    elseif ($h.State -eq 'PATCHED' -and $direction -eq 'stock') { $old = $patchText; $new = $stockText }
    else { $old = $null }
    $edits = @()
    if ($null -ne $old) { $edits += @{ Kind = 'region'; Patch = 'usageaccounts'; Off = [int64]($dataOffset + $h.Chunk.Offset + $h.M.Index); Old = $old; New = $new; Chunk = $h.Chunk; ChunkText = $h.Text } }
    $what = if ($h.State -eq 'PATCHED') { 'all accounts' } else { 'own account only (stock)' }
    return @{ State = $h.State; Detail = "popover usage in $(Split-Path $h.Chunk.Path -Leaf), $what"; Edits = $edits }
}

# --- chunk-level write plan ------------------------------------------------------
# Region edits are folded per chunk; the chat-chunk edit replaces the whole
# chunk. One chunk may appear once; otherwise the two patches would interleave.
function Build-ChunkPlan([object[]]$edits) {
    $plan = @()
    $regionEdits = @($edits | Where-Object { $_.Kind -eq 'region' })
    $chunkEdits  = @($edits | Where-Object { $_.Kind -eq 'chunk' })
    # A region edit in a chunk that also gets a whole-chunk rewrite (nofloat and
    # noterm-v3 both live in the chat chunk) is folded into the rewritten text. The
    # rewrite can shift offsets, so each region edit is found again by its exact
    # surrounding context, which must occur once in the rewritten text.
    foreach ($e in $chunkEdits) {
        $mine = @($regionEdits | Where-Object { $_.Chunk.Offset -eq $e.Chunk.Offset })
        if ($mine.Count -eq 0) { continue }
        $absBase = $dataOffset + [int64]$e.Chunk.Offset
        $newText = $e.NewChunkText
        # edits close together (the two nofloat sites sit ~40 bytes apart) would see each
        # other in their context, so each edit is also applied to this copy of the old text
        $oldText = $e.ChunkText
        foreach ($r in ($mine | Sort-Object Off)) {
            $rel = [int]($r.Off - $absBase)
            if ($oldText.Substring($rel, $r.Old.Length) -cne $r.Old) { throw "refusing: $($r.Patch): expected '$($r.Old)' not found at chunk offset $rel - investigate" }
            $pre  = $oldText.Substring([Math]::Max(0, $rel - 48), [Math]::Min(48, $rel))
            $post = $oldText.Substring($rel + $r.Old.Length, [Math]::Min(48, $oldText.Length - $rel - $r.Old.Length))
            $at = $newText.IndexOf($pre + $r.Old + $post, [System.StringComparison]::Ordinal)
            if ($at -lt 0 -or $newText.IndexOf($pre + $r.Old + $post, $at + 1, [System.StringComparison]::Ordinal) -ge 0) {
                throw "refusing: $($r.Patch) edit cannot be placed uniquely inside the $($e.Patch) rewrite - investigate"
            }
            $newText = $newText.Remove($at + $pre.Length, $r.Old.Length).Insert($at + $pre.Length, $r.New)
            $oldText = $oldText.Remove($rel, $r.Old.Length).Insert($rel, $r.New)
        }
        $e.NewChunkText = $newText
        $regionEdits = @($regionEdits | Where-Object { $_.Chunk.Offset -ne $e.Chunk.Offset })
    }
    foreach ($g in ($regionEdits | Group-Object { $_.Chunk.Offset })) {
        $first = $g.Group[0]
        $text = $first.ChunkText
        $absBase = $dataOffset + [int64]$first.Chunk.Offset
        foreach ($e in ($g.Group | Sort-Object Off)) {
            $rel = [int]($e.Off - $absBase)
            if ($rel -lt 0 -or ($rel + $e.Old.Length) -gt $text.Length) { throw "refusing: $($e.Patch) edit offset outside its chunk - investigate" }
            if ($text.Substring($rel, $e.Old.Length) -cne $e.Old) { throw "refusing: $($e.Patch): expected '$($e.Old)' not found at chunk offset $rel - investigate" }
            if ($e.Old.Length -ne $e.New.Length) { throw "refusing: $($e.Patch) replacement changes length; asar would corrupt" }
            $text = $text.Remove($rel, $e.Old.Length).Insert($rel, $e.New)
        }
        $plan += @{ Chunk = $first.Chunk; OldText = $first.ChunkText; NewText = $text }
    }
    foreach ($e in $chunkEdits) {
        $plan += @{ Chunk = $e.Chunk; OldText = $e.ChunkText; NewText = $e.NewChunkText }
    }
    $dups = @($plan | Group-Object { $_.Chunk.Offset } | Where-Object Count -gt 1)
    if ($dups.Count -gt 0) { throw "refusing: two patches target the same chunk ($(($dups | ForEach-Object { $_.Group[0].Chunk.Path }) -join ', ')) - investigate" }
    return ,$plan
}

# --- write one chunk with compare-and-swap, then verify by fresh byte-read -------
function Write-ChunkEntry([object]$entry) {
    $chunkOff = $dataOffset + [int64]$entry.Chunk.Offset
    $chunkSize = [int]$entry.Chunk.Size
    $newBytes = $Latin1.GetBytes($entry.NewText)
    if ($newBytes.Length -ne $chunkSize) { throw 'refusing: chunk byte length changed; asar would corrupt' }
    $oldBytes = $Latin1.GetBytes($entry.OldText)
    $f = [System.IO.File]::Open($AsarPath, 'Open', 'ReadWrite', 'Read')
    try {
        $f.Position = $chunkOff
        $now = New-Object byte[] $chunkSize
        $null = $f.Read($now, 0, $chunkSize)
        if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$now, [byte[]]$oldBytes)) {
            throw 'ABORT: chunk changed since it was read (compare-and-swap failed); nothing written.'
        }
        $f.Position = $chunkOff
        $f.Write($newBytes, 0, $newBytes.Length)
        $f.Flush()
    } finally { $f.Close() }
    # verify by fresh read
    $f = [System.IO.File]::Open($AsarPath, 'Open', 'Read', 'ReadWrite')
    try {
        $f.Position = $chunkOff
        $v = New-Object byte[] $chunkSize
        $null = $f.Read($v, 0, $chunkSize)
        if ([BitConverter]::ToString($v) -ne [BitConverter]::ToString($newBytes)) { throw 'ABORT: post-write verification failed.' }
    } finally { $f.Close() }
}

function Backup-Asar([string]$kind) {
    $sha = (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash
    $hash8 = $sha.Substring(0, 8)
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $bak = Join-Path $BackupDir ("server.asar.{0}-{1}.asar" -f $kind, $hash8)
    if (Test-Path -LiteralPath $bak) {
        Write-Output ("backup      : keeping existing {0} (sha256 {1})" -f $bak, $sha)
    } else {
        Copy-Item -LiteralPath $AsarPath -Destination $bak
        $bakLen = (Get-Item -LiteralPath $bak).Length
        if ($bakLen -ne (Get-Item -LiteralPath $AsarPath).Length) { throw "ABORT: backup size mismatch; nothing written." }
        Write-Output ("backup      : {0} (sha256 {1})" -f $bak, $sha)
    }
    # each update brings a new stock file; keep the newest three backups
    Get-ChildItem -LiteralPath $BackupDir -Filter 'server.asar.*.asar' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
}

# --- main -------------------------------------------------------------------------
$patches = @(
    @{ Name = 'slowrpc';       Fn = 'Resolve-SlowRpc';       Default = $true },
    @{ Name = 'opencode';      Fn = 'Resolve-OpenCode';      Default = $false },
    @{ Name = 'noterm-v3';     Fn = 'Resolve-NoTermV3';      Default = $true },
    @{ Name = 'noterm-open';   Fn = 'Resolve-NotermOpen';    Default = $true },
    @{ Name = 'nofloat';       Fn = 'Resolve-NoFloat';       Default = $true },
    @{ Name = 'galaxy';        Fn = 'Resolve-Galaxy';        Default = $true },
    @{ Name = 'scriptbuttons'; Fn = 'Resolve-ScriptButtons'; Default = $true },
    @{ Name = 'browserdark';   Fn = 'Resolve-BrowserDark';   Default = $false },
    @{ Name = 'sidebarsecs';   Fn = 'Resolve-SidebarSeconds'; Default = $true },
    @{ Name = 'usageaccounts'; Fn = 'Resolve-UsageAccounts'; Default = $true }
)

$wanted = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { Write-Output "refusing: $ConfigPath is not valid JSON - fix it first"; exit 1 }
    if ($cfg.PSObject.Properties['serverPatches']) { $wanted = $cfg.serverPatches }
}
foreach ($pt in $patches) {
    $on = $pt.Default
    if ($wanted -and $wanted.PSObject.Properties[$pt.Name]) { $on = $wanted.($pt.Name) -eq $true }
    $pt.Want = if ($mode -eq 'Revert' -or -not $on) { 'stock' } else { 'patched' }
    $pt.Expect = if ($pt.Want -eq 'patched') { 'PATCHED' } else { 'ORIGINAL' }
}

function Test-InSync($pt) { return $pt.R.State -eq $pt.Expect }

try {
    foreach ($pt in $patches) { $pt.R = & $pt.Fn $(if ($mode -eq 'Status') { 'none' } else { $pt.Want }) }

    Write-Output ("asar        : {0}  ({1} bytes, sha256 {2})" -f $AsarPath, $sizeBefore, $shaBefore.Substring(0, 16))
    foreach ($pt in $patches) { Write-Output ("{0,-13}: {1}  (wanted {2}; {3})" -f $pt.Name, $pt.R.State, $pt.Expect, $pt.R.Detail) }
    $unknown = @($patches | Where-Object { $_.R.State -eq 'UNKNOWN' })

    if ($mode -eq 'Status') {
        $outOfSync = @($patches | Where-Object { $_.R.State -ne 'UNKNOWN' -and -not (Test-InSync $_) })
        Write-Output ("state       : {0}" -f $(if ($unknown.Count) { 'UNKNOWN' } elseif ($outOfSync.Count) { 'OUT-OF-SYNC' } else { 'IN-SYNC' }))
        exit 0
    }

    # an upstream shape change on one patch must not block the others
    $skipped = @($unknown | ForEach-Object { $_.Name })
    if ($skipped.Count) { Write-Output ("note        : skipping unrecognizable shape(s): {0} (upstream changed; nothing written for them)" -f ($skipped -join ', ')) }

    $active = @($patches | Where-Object { $_.R.State -ne 'UNKNOWN' })
    $pending = @($active | ForEach-Object { $_.R.Edits } | Where-Object { $_ })
    if ($pending.Count -eq 0) {
        if ($skipped.Count) { Write-Output 'nothing to apply: resolvable patches are already in the requested state.'; exit 0 }
        Write-Output 'Already in the requested state; nothing to do.'
        exit 2
    }
    foreach ($e in $pending) {
        if ($e.Kind -eq 'chunk') {
            Write-Output ("pending     : {0}: rewrite whole chunk {1} ({2} bytes)" -f $e.Patch, (Split-Path $e.Chunk.Path -Leaf), $e.Chunk.Size)
        } else {
            $show = if ($e.Old.Length -gt 60) { $e.Old.Substring(0, 60) + '...' } else { $e.Old }
            Write-Output ("pending     : {0}: '{1}' at offset {2}" -f $e.Patch, $show, $e.Off)
        }
    }

    Backup-Asar $(if ($mode -eq 'Apply') { 'pre-apply' } else { 'pre-revert' })

    $plan = Build-ChunkPlan $pending
    $syns = @()
    foreach ($entry in $plan) {
        $syn = Test-Syntax $entry.NewText
        $syns += ("{0}: {1}" -f (Split-Path $entry.Chunk.Path -Leaf), $syn)
        if ($syn -match 'FAILED') { Write-Output ("refusing: node --check failed on {0}; nothing written. {1}" -f $entry.Chunk.Path, $syn); exit 1 }
    }
    foreach ($entry in $plan) {
        Write-ChunkEntry $entry
        Write-Output ("wrote       : chunk {0} ({1} bytes), verified by fresh byte-read" -f (Split-Path $entry.Chunk.Path -Leaf), $entry.Chunk.Size)
    }

    Clear-ChunkCache
    $sizeAfter = (Get-Item -LiteralPath $AsarPath).Length
    $shaAfter  = (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash
    if ($sizeAfter -ne $sizeBefore) { throw "ABORT: file size changed ($sizeBefore -> $sizeAfter)" }
    foreach ($pt in $active) {
        if (@($pt.R.Edits).Count -eq 0) { continue }
        $after = & $pt.Fn 'none'
        if ($after.State -ne $pt.Expect) {
            Write-Output ("refusing: post-write audit says {0} is {1}, expected {2}" -f $pt.Name, $after.State, $pt.Expect)
            exit 1
        }
    }
    Write-Output ("syntax      : {0}" -f ($syns -join '; '))
    if ($skipped.Count) { Write-Output ("skipped     : {0} (shape not recognized in this build)" -f ($skipped -join ', ')) }
    Write-Output ("Patch complete. {0} chunks rewritten, all writes verified by byte-read; size unchanged ({1} bytes); asar sha256 {2}" -f $plan.Count, $sizeAfter, $shaAfter)
    Write-Output $(if ($skipped.Count) { 'state       : IN-SYNC for resolvable patches (skipped: ' + ($skipped -join ', ') + ')' } else { 'state       : IN-SYNC' })
    exit 0
}
catch {
    Write-Output ("ERROR: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    exit 1
}
