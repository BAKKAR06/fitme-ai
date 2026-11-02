@echo off
cd /d "%~dp0"
set "LOG=%~dp0bench_avatar_log.txt"
echo FitMe 7-model benchmark %DATE% %TIME% > "%LOG%"
backend\.venv\Scripts\python.exe -u benchmark\bench_avatar.py >> "%LOG%" 2>&1
echo EXIT %ERRORLEVEL% >> "%LOG%"
