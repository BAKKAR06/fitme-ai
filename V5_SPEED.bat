@echo off
cd /d "%~dp0"
echo V5 speed lab started %DATE% %TIME%
gpu_server\.venv\Scripts\python.exe -u experiments\v5_speed.py
echo EXIT %ERRORLEVEL%
pause
