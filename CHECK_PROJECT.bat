@echo off
setlocal
cd /d "%~dp0"
set "LOG=%~dp0check_log.txt"
echo FitMe project check %DATE% %TIME% > "%LOG%"
echo. >> "%LOG%"
echo ===== flutter --version ===== >> "%LOG%"
call flutter --version >> "%LOG%" 2>&1
echo ===== flutter pub get ===== >> "%LOG%"
call flutter pub get >> "%LOG%" 2>&1
echo ===== flutter analyze ===== >> "%LOG%"
call flutter analyze >> "%LOG%" 2>&1
echo ===== flutter test ===== >> "%LOG%"
call flutter test >> "%LOG%" 2>&1
echo ===== backend python ===== >> "%LOG%"
set "PY=python"
if exist "backend\.venv\Scripts\python.exe" set "PY=backend\.venv\Scripts\python.exe"
%PY% --version >> "%LOG%" 2>&1
%PY% -m py_compile backend\app\main.py backend\app\hf_space.py backend\configure_remote.py benchmark\bench_spaces.py benchmark\evaluate.py >> "%LOG%" 2>&1 && echo py_compile OK >> "%LOG%"
%PY% -c "import fastapi, uvicorn, httpx, PIL, multipart; print('backend deps OK')" >> "%LOG%" 2>&1
%PY% -c "import rembg; print('rembg OK')" >> "%LOG%" 2>&1
echo ===== DONE ===== >> "%LOG%"
type "%LOG%"
echo.
echo Log saved: %LOG%
pause
endlocal
