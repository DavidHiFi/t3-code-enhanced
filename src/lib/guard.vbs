' guard.vbs - part of T3 Code Enhanced
'
' Hidden launcher for guard.ps1 (no console window). Starts the guard again whenever
' it exits: a PowerShell update ends every running pwsh, and Task Scheduler counts
' that exit as success, so its restart-on-failure never fires. Exit code 3 means
' another guard already runs; then this launcher quits too.
Dim sh, fso, guard, rc
Set sh = CreateObject("Wscript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
guard = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "guard.ps1")
On Error Resume Next
Do
    Err.Clear
    rc = sh.Run("pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & guard & """", 0, True)
    If Err.Number = 0 And rc = 3 Then WScript.Quit 0
    WScript.Sleep 20000   ' pwsh may be mid-update; try again in 20 s
Loop
