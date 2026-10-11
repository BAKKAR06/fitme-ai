@echo off
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo Creating benchmark environment...
  python -m venv .venv
  .venv\Scripts\python.exe -m pip install --upgrade pip
  .venv\Scripts\python.exe -m pip install httpx pillow
)
if not defined HF_TOKEN (
  echo Free Hugging Face token gives more GPU quota: huggingface.co/settings/tokens
  set /p "HF_TOKEN=HF_TOKEN (Enter to skip): "
)
if not exist "test_set\pairs.csv" (
  .venv\Scripts\python.exe bench_spaces.py --demo
) else (
  .venv\Scripts\python.exe bench_spaces.py
)
echo.
echo Results: %~dp0results\grids
pause
endlocal
