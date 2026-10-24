@echo off
rem Double-click to install or update T3 Code Enhanced. Needs PowerShell 7.
where pwsh >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 is needed. Install it with:  winget install Microsoft.PowerShell
    echo Then run this file again.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
