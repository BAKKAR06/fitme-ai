@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo ================================================================
echo FitMe Backend - FASHN VTON 1.5 / KAGGLE GPU
echo URL FIX v0.10.1
echo ================================================================
echo.

if not exist ".venv\Scripts\activate.bat" (
  echo ERROR: backend\.venv not found.
  pause
  exit /b 1
)

echo Paste the tunnel value from Kaggle.
echo You can paste ANY of these forms:
echo   https://abc.trycloudflare.com
echo   abc.trycloudflare.com
echo   FITME_AI_URL=https://abc.trycloudflare.com
echo   set "FITME_AI_URL=https://abc.trycloudflare.com"
echo.
set "FITME_REMOTE_AI_URL="
set /p "FITME_REMOTE_AI_URL=FITME_AI_URL: "

if not defined FITME_REMOTE_AI_URL (
  echo.
  echo ERROR: URL is empty.
  pause
  exit /b 1
)

set "FITME_AI_PROVIDER=remote_fashn"

call ".venv\Scripts\activate.bat"

echo.
echo Starting backend...
echo Raw pasted URL: %FITME_REMOTE_AI_URL%
echo Backend: http://127.0.0.1:8000
echo.
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000

pause
endlocal
