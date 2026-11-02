@echo off
cd /d "%~dp0"
gpu_server\.venv\Scripts\python.exe -u experiments\v4_lab3.py
echo EXIT %ERRORLEVEL%
pause
