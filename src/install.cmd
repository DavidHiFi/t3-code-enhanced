@echo off
rem Double-click to install or update T3 Code Enhanced.
rem Needs PowerShell 7; if it is missing this offers to install it with winget first.
setlocal
where pwsh >nul 2>&1
if errorlevel 1 (
    if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
        set "PATH=%ProgramFiles%\PowerShell\7;%PATH%"
    ) else (
        echo T3 Code Enhanced needs PowerShell 7, which is not installed yet.
        where winget >nul 2>&1
        if errorlevel 1 (
            echo Get it from https://aka.ms/powershell and run this file again.
            pause
            exit /b 1
        )
        choice /c YN /m "Install PowerShell 7 now with winget"
        if errorlevel 2 exit /b 1
        winget install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements
        set "PATH=%ProgramFiles%\PowerShell\7;%PATH%"
    )
)
where pwsh >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 still was not found. Restart Windows or open a new window, then run this file again.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
