@echo off
chcp 65001 >nul
cd /d "%~dp0"
gpu_server\.venv\Scripts\python.exe gpu_server\make_kaggle_notebook.py
if errorlevel 1 (pause & exit /b 1)
echo.
echo 1. kaggle.com - Create - New Notebook - File - Import Notebook - choose KAGGLE_PRIVATE\FitMe_Kaggle_GPU.ipynb
echo 2. Settings: Accelerator = GPU T4 x2, Internet = On
echo 3. Save Version - Save ^& Run All (Commit)
echo The laptop finds the Kaggle GPUs by itself in 1-2 minutes after they start.
explorer KAGGLE_PRIVATE
pause
