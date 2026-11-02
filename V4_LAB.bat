@echo off
cd /d "%~dp0"
echo Lab started %DATE% %TIME%
gpu_server\.venv\Scripts\python.exe -u experiments\v4_lab.py
echo EXIT %ERRORLEVEL%
pause
