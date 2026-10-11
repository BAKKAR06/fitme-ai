@echo off
setlocal
cd /d "%~dp0"
echo Creating FitMe backend environment...
if not exist ".venv\Scripts\python.exe" python -m venv .venv
call ".venv\Scripts\activate.bat"
python -m pip install --upgrade pip
pip install -r requirements.txt
if errorlevel 1 (
  echo.
  echo ERROR: base backend dependencies failed to install.
  pause
  exit /b 1
)
echo.
echo Installing optional avatar cutout (rembg)...
pip install -r requirements-cutout.txt
if errorlevel 1 (
  echo.
  echo WARNING: rembg did not install. Try-on works, avatar AI cutout will not.
  echo Python 3.11 or 3.12 is recommended for rembg/onnxruntime.
)
echo.
echo Backend ready.
echo Next: START_FITME.bat in the project root.
pause
endlocal
