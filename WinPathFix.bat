@echo off
:: WinPathFix Launcher
:: Requests Administrator privileges and runs the PowerShell script

NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "WinPathFix.ps1"
