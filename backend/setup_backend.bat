@echo off
cd /d "%~dp0"
echo Creating FitMe backend environment...
python -m venv .venv
call ".venv\Scripts\activate.bat"
python -m pip install --upgrade pip
pip install -r requirements.txt
echo.
echo Backend ready.
echo Next: run_backend.bat
pause
