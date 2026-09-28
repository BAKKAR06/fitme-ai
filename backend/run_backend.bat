@echo off
cd /d "%~dp0"
call ".venv\Scripts\activate.bat"
set FITME_AI_PROVIDER=mock
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
