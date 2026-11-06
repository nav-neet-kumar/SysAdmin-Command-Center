@echo off
rem Starts the helper in a visible window (shows any error) and opens the control panel.
cd /d "%~dp0"
start "" "%~dp0CommandCenter.html"
powershell.exe -NoProfile -File "%~dp0helper.ps1"
if errorlevel 1 pause
