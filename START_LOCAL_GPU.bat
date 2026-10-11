@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title FitMe - local GPU
set "LOG=%~dp0start_log.txt"
echo FitMe local start %DATE% %TIME% > "%LOG%"

if not exist "gpu_server\.venv\Scripts\python.exe" (
  echo ERROR: run INSTALL_LOCAL_GPU.bat first. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)
if not exist "backend\.venv\Scripts\python.exe" (
  echo ERROR: run INSTALL_LOCAL_GPU.bat first. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)

echo Closing old processes on ports 7860 and 8000...
for %%Q in (7860 8000) do (
  for /f "tokens=5" %%P in ('netstat -aon ^| findstr ":%%Q " ^| findstr "LISTENING"') do taskkill /PID %%P /F >nul 2>&1
)

echo [1/3] Starting FASHN on your GPU (first start loads the model, up to 2-3 min)...
start "FitMe GPU (FASHN)" /D "%~dp0gpu_server" cmd /k .venv\Scripts\python.exe fashn_server.py
powershell -NoProfile -Command "$ok=$false; for($i=0;$i -lt 120;$i++){ try { $r=Invoke-RestMethod 'http://127.0.0.1:7860/health' -TimeoutSec 3; if($r.status -eq 'ready'){ $ok=$true; break } } catch {}; Start-Sleep -Seconds 3 }; if(-not $ok){ exit 1 }"
if errorlevel 1 (
  echo ERROR: GPU server did not start - see the "FitMe GPU (FASHN)" window. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)
powershell -NoProfile -Command "Invoke-RestMethod 'http://127.0.0.1:7860/health' | ConvertTo-Json" >> "%LOG%" 2>&1
echo GPU server ready >> "%LOG%"

echo [2/3] Starting backend...
set "FITME_REMOTE_AI_URL=http://127.0.0.1:7860"
set "FITME_AI_PROVIDER=kaggle"
set "FITME_FASHN_STEPS=20"
start "FitMe Backend" /D "%~dp0backend" cmd /k .venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
powershell -NoProfile -Command "$ok=$false; for($i=0;$i -lt 40;$i++){ try { $r=Invoke-RestMethod 'http://127.0.0.1:8000/api/v1/ai/status' -TimeoutSec 5; if($r.online){ $ok=$true; break } } catch {}; Start-Sleep -Seconds 1 }; if(-not $ok){ exit 1 }"
if errorlevel 1 (
  echo ERROR: backend did not start - see the "FitMe Backend" window. >> "%LOG%"
  type "%LOG%" & pause & exit /b 1
)
echo Backend ready: http://127.0.0.1:8000 >> "%LOG%"

echo [3/3] Phone...
set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=adb"
set "DEVICE="
for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices 2^>nul') do (
  if "%%B"=="device" if not defined DEVICE set "DEVICE=%%A"
)
if defined DEVICE (
  echo Phone: !DEVICE! >> "%LOG%"
  "%ADB%" -s !DEVICE! reverse tcp:8000 tcp:8000 >> "%LOG%" 2>&1
  type "%LOG%"
  echo.
  echo Starting the app on the phone...
  flutter run -d !DEVICE!
) else (
  echo No phone connected by USB. >> "%LOG%"
  type "%LOG%"
  echo.
  echo Servers are running. Connect the phone by USB and run this file again,
  echo or open http://127.0.0.1:8000/docs to test in the browser.
  pause
)
endlocal
