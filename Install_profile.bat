@echo off
:: PS1nstaller Launcher
:: This bypasses the execution policy and launches the script automatically.

echo Initializing PS1nstaller...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Powershell_Profile_Install.ps1"

echo.
pause
