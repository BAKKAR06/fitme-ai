@echo off
cd /d "%~dp0"
rem Opens the FitMe web admin panel (full user table, load charts, CSV export) in the browser.
set "KEY="
for /f "usebackq delims=" %%K in (`"gpu_server\.venv\Scripts\python.exe" gpu_server\discovery_value.py key`) do set "KEY=%%K"
start "" "http://127.0.0.1:8000/admin#key=%KEY%"
