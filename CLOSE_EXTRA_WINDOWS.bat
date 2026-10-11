@echo off
rem Closes finished FitMe script windows and old server copies. Running servers stay.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu_server\close_extra_windows.ps1" > "%~dp0close_log.txt" 2>&1
exit /b 0
