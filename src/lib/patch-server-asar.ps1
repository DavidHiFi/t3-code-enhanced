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
       OrigRe = 'timeoutOption\("5 seconds"\)'; PatchRe = 'timeoutOption\("9 seconds"\)'; Stock = '5' },
    @{ Name = '/api/info readiness (INFO_TIMEOUT)'; Region = 'packages/provider-opencode/src/server/v2/OpenCode2Server.ts'
       OrigRe = 'const \w+ = "5 seconds";'; PatchRe = 'const \w+ = "9 seconds";'; Stock = '5' },
    @{ Name = 'version probe (OPENCODE_VERSION_PROBE_TIMEOUT)'; Region = 'packages/provider-opencode/src/server/versionProbe.ts'
       OrigRe = 'const \w+ = "4 seconds";'; PatchRe = 'const \w+ = "9 seconds";'; Stock = '4'
       UpstreamFixedRe = 'const \w+ = "10 seconds";' }
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
        if (-not $mark) { $siteResults += [pscustomobject]@{ Name = $s.Name; State = 'UNKNOWN'; Detail = "region marker for '$($s.Region)' not found" }; continue }
        $rStart = $mark.Index
        $endMark = $text.IndexOf('//#endregion', $rStart)
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
            $newVal = [regex]::Replace($m.Value, '"\d+ seconds"', ('"' + $digit + ' seconds"'))
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
    $kinds = @(
        @{ Kind = 'preview'; Tail = '(?<src>@I@)\((?<sv>@I@)\.resourceId\)\)' },
        @{ Kind = 'device';  Tail = ('\{kind:' + $bt + 'device' + $bt + ',\.\.\.(?<sv>@I@)\.target\}\)') }
    )
    $cands = @($script:files | Where-Object { $_.Path -match '/client/assets/[^/]*\.js$' })
    $sites = @()
    foreach ($c in $cands) {
        $text = Get-ChunkText $c.Offset $c.Size
        if (-not $text.Contains($anchor)) { continue }
        foreach ($k in $kinds) {
            $stockRe = ('(?<mp>@I@)\.getState\(\)\.open\((?<r>@I@),' + $k.Tail).Replace('@I@', $I)
            $patchRe = ('!1&&(?<mp>@I@)\.getState\(\)\((?<r>@I@), ' + $k.Tail).Replace('@I@', $I)
            foreach ($pair in @(@('ORIGINAL', $stockRe), @('PATCHED', $patchRe))) {
                foreach ($m in [regex]::Matches($text, $pair[1])) {
                    $r = [regex]::Escape($m.Groups['r'].Value)
                    $after = $text.Substring($m.Index + $m.Length, [Math]::Min(400, $text.Length - $m.Index - $m.Length))
                    $ctx = ('^[^;]{0,260}?(?<ps>@I@)\.getState\(\)\.setMaximized\(' + $r + ',!1\),\k<ps>\.getState\(\)\.close\(' + $r + '\)').Replace('@I@', $I)
                    if (-not [regex]::IsMatch($after, $ctx)) { continue }
                    $sites += [pscustomobject]@{ Kind = $k.Kind; State = $pair[0]; Chunk = $c; Text = $text; M = $m }
                }
            }
        }
    }
    foreach ($k in $kinds) {
        $n = @($sites | Where-Object Kind -eq $k.Kind).Count
        if ($n -ne 1) { return @{ State = 'UNKNOWN'; Detail = "$($k.Kind) float site matched $n times (expected 1)"; Edits = @() } }
    }
    $p = $sites | Where-Object Kind -eq 'preview'
    $d = $sites | Where-Object Kind -eq 'device'
    if ($p.Chunk.Offset -ne $d.Chunk.Offset) { return @{ State = 'UNKNOWN'; Detail = 'preview and device float sites are in different chunks'; Edits = @() } }
    foreach ($g in @('mp', 'r', 'sv')) {
        if ($p.M.Groups[$g].Value -ne $d.M.Groups[$g].Value) { return @{ State = 'UNKNOWN'; Detail = "float sites disagree on the captured '$g' name"; Edits = @() } }
    }
    $chunk = $p.Chunk
    $name = Split-Path $chunk.Path -Leaf
    $short = "chunk $name (offset $($chunk.Offset), size $($chunk.Size))"
    $edits = @()
    foreach ($s in @($p, $d)) {
        $mp = $s.M.Groups['mp'].Value; $r = $s.M.Groups['r'].Value
        $stockHead = $mp + '.getState().open(' + $r + ','
        $patchHead = '!1&&' + $mp + '.getState()(' + $r + ', '
        if ($stockHead.Length -ne $patchHead.Length) { return @{ State = 'UNKNOWN'; Detail = 'float edit would change length'; Edits = @() } }
        if ($s.State -eq 'ORIGINAL' -and $direction -eq 'patched') { $old = $stockHead; $new = $patchHead }
        elseif ($s.State -eq 'PATCHED' -and $direction -eq 'stock') { $old = $patchHead; $new = $stockHead }
        else { continue }
        $edits += @{ Kind = 'region'; Patch = 'nofloat'; Off = [int64]($dataOffset + $chunk.Offset + $s.M.Index); Old = $old; New = $new; Chunk = $chunk; ChunkText = $s.Text }
    }
    $state = if ($p.State -eq $d.State) { $p.State } else { 'MIXED' }
    return @{ State = $state; Detail = "$short, preview=$($p.State), device=$($d.State)"; Edits = $edits }
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
    $reAStock = '(?<a>[\w$]+)\.paletteThemeActive&&!\k<a>\.paletteThemeAllowsArtwork&&(?=\k<a>\.mode===' + $bq + 'artwork' + $bq + '\?' + $bq + 'pill' + $bq + ':\k<a>\.mode)'
    $reAPatch = '!1&&(?<pad> +)(?=(?<a>[\w$]+)\.mode===' + $bq + 'artwork' + $bq + '\?' + $bq + 'pill' + $bq + ':\k<a>\.mode)'
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
function Resolve-ScriptButtons([string]$direction) {
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
                if (-not $t.Contains('D(' + $n + ')')) { continue }
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
        foreach ($r in $mine) {
            $rel = [int]($r.Off - $absBase)
            if ($e.ChunkText.Substring($rel, $r.Old.Length) -cne $r.Old) { throw "refusing: $($r.Patch): expected '$($r.Old)' not found at chunk offset $rel - investigate" }
            $pre  = $e.ChunkText.Substring([Math]::Max(0, $rel - 48), [Math]::Min(48, $rel))
            $post = $e.ChunkText.Substring($rel + $r.Old.Length, [Math]::Min(48, $e.ChunkText.Length - $rel - $r.Old.Length))
            $at = $newText.IndexOf($pre + $r.Old + $post, [System.StringComparison]::Ordinal)
            if ($at -lt 0 -or $newText.IndexOf($pre + $r.Old + $post, $at + 1, [System.StringComparison]::Ordinal) -ge 0) {
                throw "refusing: $($r.Patch) edit cannot be placed uniquely inside the $($e.Patch) rewrite - investigate"
            }
            $newText = $newText.Remove($at + $pre.Length, $r.Old.Length).Insert($at + $pre.Length, $r.New)
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
    @{ Name = 'browserdark';   Fn = 'Resolve-BrowserDark';   Default = $true }
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
