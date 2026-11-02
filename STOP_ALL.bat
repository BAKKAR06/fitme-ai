@echo off
rem Stops everything FitMe: GPU server, backend, tunnel, experiments. Run START_LOCAL_GPU.bat to start again.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu_server\close_extra_windows.ps1" -StopAll > "%~dp0close_log.txt" 2>&1
taskkill /IM cloudflared.exe /F >nul 2>&1
for %%Q in (7860 8000) do (
  for /f "tokens=5" %%P in ('netstat -aon ^| findstr ":%%Q " ^| findstr "LISTENING"') do taskkill /PID %%P /F >nul 2>&1
)
exit /b 0
