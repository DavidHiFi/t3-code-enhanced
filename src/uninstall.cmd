@echo off
rem Double-click to remove T3 Code Enhanced. Needs PowerShell 7.
where pwsh >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 is needed. Install it with:  winget install Microsoft.PowerShell
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause
