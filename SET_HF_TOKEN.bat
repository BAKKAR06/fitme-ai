@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo  Free Hugging Face token = more free cloud GPU minutes for the extra models
echo  (Leffa, FitDiT, IDM-VTON, OOTDiffusion, FASHN cloud).
echo.
echo  1. Sign in at https://huggingface.co  (free account)
echo  2. Open https://huggingface.co/settings/tokens  -  "Create new token"  -  type: Read
echo  3. Copy the token (starts with hf_) and paste it below, then press Enter.
echo     Leave empty and press Enter to remove the saved token.
echo.
echo  The token is saved only on this laptop: backend\data\hf_token.txt (never sent to GitHub).
echo.
set "TOKEN="
set /p "TOKEN=Token: "
if not exist "backend\data" mkdir "backend\data"
if "%TOKEN%"=="" (
  del /q "backend\data\hf_token.txt" >nul 2>&1
  echo Token removed.
) else (
  > "backend\data\hf_token.txt" echo %TOKEN%
  echo Token saved. It is used from the next try-on, no restart needed.
)
echo.
pause
