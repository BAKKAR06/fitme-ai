@echo off
cd /d "%~dp0"
gpu_server\.venv\Scripts\python.exe gpu_server\diag.py
timeout /t 8 >nul
