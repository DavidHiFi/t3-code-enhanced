# T3 Code program-file icon swap (2026-11-22). Started hidden by local-app-icon.cjs when T3 quits.
# Waits until no process runs from the program file, checks the file is still the one T3 saw at quit
# (an update would have replaced it), then writes the icon into a copy and swaps the copy in.
# The old file is kept as .icon-old until the swap succeeds and put back on any failure.
param(
	[Parameter(Mandatory)][string]$Exe,
	[Parameter(Mandatory)][string]$Ico,
	[Parameter(Mandatory)][ValidateSet('riced', 'original')][string]$Choice,
	[Parameter(Mandatory)][long]$Size,
	[Parameter(Mandatory)][double]$MtimeMs,
	[int]$QuietSeconds = 5,
	[int]$GiveUpMinutes = 10,
	[string]$StateFile = (Join-Path $env:USERPROFILE '.t3\icons\exe-state.json')
)
$ErrorActionPreference = 'Stop'
$t3 = Join-Path $env:USERPROFILE '.t3'
$rcedit = Join-Path $t3 'bin\rcedit-x64.exe'
$logFile = Join-Path $t3 'local-main.log'
function Write-SwapLog([string]$m) {
	try { Add-Content -LiteralPath $logFile -Value ('{0} appIcon swap: {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $m) -Encoding utf8 } catch {}
}
function Test-Running {
	@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe }).Count -gt 0
}
function Test-Same {
	$f = Get-Item -LiteralPath $Exe
	$ms = ([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
	($f.Length -eq $Size) -and ([math]::Abs($ms - $MtimeMs) -lt 2)
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\T3AppIconSwap')
if (-not $mutex.WaitOne(0)) { Write-SwapLog 'another swap is already waiting'; exit 0 }
try {
	$deadline = (Get-Date).AddMinutes($GiveUpMinutes)
	$quietSince = $null
	while ($true) {
		if (Test-Running) { $quietSince = $null }
		elseif (-not $quietSince) { $quietSince = Get-Date }
		elseif (((Get-Date) - $quietSince).TotalSeconds -ge $QuietSeconds) { break }
		if ((Get-Date) -gt $deadline) { Write-SwapLog 'T3 kept running; trying again at the next close'; exit 0 }
		Start-Sleep -Milliseconds 1000
	}
	if (-not (Test-Same)) { Write-SwapLog 'program file changed since quit (update); trying again at the next close'; exit 0 }

	$new = "$Exe.icon-new"; $old = "$Exe.icon-old"
	Remove-Item -LiteralPath $new, $old -Force -ErrorAction SilentlyContinue
	Copy-Item -LiteralPath $Exe -Destination $new
	$p = Start-Process -FilePath $rcedit -ArgumentList @("`"$new`"", '--set-icon', "`"$Ico`"") -WindowStyle Hidden -Wait -PassThru
	if ($p.ExitCode -ne 0) { Remove-Item -LiteralPath $new -Force; Write-SwapLog "icon tool failed ($($p.ExitCode))"; exit 1 }
	if ((Test-Running) -or -not (Test-Same)) { Remove-Item -LiteralPath $new -Force; Write-SwapLog 'T3 started or updated during the swap; left alone'; exit 0 }

	Move-Item -LiteralPath $Exe -Destination $old
	try { Move-Item -LiteralPath $new -Destination $Exe }
	catch { Move-Item -LiteralPath $old -Destination $Exe; Write-SwapLog "swap failed, original put back: $($_.Exception.Message)"; exit 1 }
	Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue

	$f = Get-Item -LiteralPath $Exe
	$state = @{ choice = $Choice; size = $f.Length; mtimeMs = ([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress
	[IO.File]::WriteAllText($StateFile, $state, (New-Object System.Text.UTF8Encoding($false)))
	Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -ArgumentList '-show' -WindowStyle Hidden
	Write-SwapLog "program file now carries the $Choice icon"
}
catch { Write-SwapLog "error: $($_.Exception.Message)"; exit 1 }
finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
