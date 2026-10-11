@echo off
cd /d "%~dp0"
set "LOG=%~dp0selftest_log.txt"
echo FitMe GPU selftest %DATE% %TIME% > "%LOG%"
gpu_server\.venv\Scripts\python.exe -u gpu_server\selftest.py >> "%LOG%" 2>&1
type "%LOG%"
timeout /t 10 >nul
