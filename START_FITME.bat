@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d D:\Projects\fitme_ai

title FitMe CLEAN MVP Launcher

echo ================================================================
echo FitMe AI CLEAN MVP
echo FASHN VTON 1.5 / Kaggle GPU
echo ================================================================
echo.
echo STEP 1:
echo In Kaggle run KAGGLE\FitMe_FASHN_VTON_Kaggle.ipynb with GPU ON.
echo Copy the FITME_AI_URL line shown at the end.
echo.

if not exist "backend\.venv\Scripts\python.exe" (
  echo ERROR: backend venv is missing.
  echo Run INSTALL_CLEAN_MVP.bat first.
  pause
  exit /b 1
)

backend\.venv\Scripts\python.exe backend\configure_remote.py
if errorlevel 1 (
  echo.
  echo Kaggle AI URL check failed.
  pause
  exit /b 1
)

echo.
echo Closing an old process on port 8000 if one exists...
for /f "tokens=5" %%P in ('netstat -aon ^| findstr ":8000" ^| findstr "LISTENING"') do (
  taskkill /PID %%P /F >nul 2>&1
)

echo Starting FitMe backend...
start "FitMe Backend" cmd /k "cd /d D:\Projects\fitme_ai\backend && .venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000"

echo Waiting for backend...
powershell -NoProfile -Command "$ok=$false; 1..30 | %% { try { $r=Invoke-RestMethod 'http://127.0.0.1:8000/health' -TimeoutSec 2; if($r.status -eq 'online'){ $ok=$true; break } } catch {}; Start-Sleep -Milliseconds 500 }; if(-not $ok){ exit 1 }"
if errorlevel 1 (
  echo ERROR: backend did not start.
  pause
  exit /b 1
)

set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=adb"

set "DEVICE=4HLNROHM79UW9DYT"
"%ADB%" -s "%DEVICE%" get-state >nul 2>&1
if errorlevel 1 set "DEVICE="

if not defined DEVICE (
  for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices') do (
    if "%%B"=="device" if not defined DEVICE set "DEVICE=%%A"
  )
)

if defined DEVICE (
  echo Android device: %DEVICE%
  "%ADB%" -s "%DEVICE%" reverse --remove-all >nul 2>&1
  "%ADB%" -s "%DEVICE%" reverse tcp:8000 tcp:8000
  echo.
  echo Starting Flutter on %DEVICE%...
  flutter run -d %DEVICE%
) else (
  echo.
  echo No Android device found.
  echo Backend is running at http://127.0.0.1:8000
  echo Connect the phone and run:
  echo   flutter run
  pause
)

endlocal
