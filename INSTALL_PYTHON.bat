@echo off
setlocal
cd /d "%~dp0"
set "LOG=%~dp0install_python_log.txt"
echo Python install %DATE% %TIME% > "%LOG%"
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
  echo Python 3.12 already installed >> "%LOG%"
  goto :check
)
echo Installing Python 3.12 from python.org via winget (user scope)...
winget install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements >> "%LOG%" 2>&1
:check
"%LOCALAPPDATA%\Programs\Python\Python312\python.exe" --version >> "%LOG%" 2>&1
if errorlevel 1 (
  echo ===== PYTHON INSTALL FAILED ===== >> "%LOG%"
) else (
  echo ===== PYTHON OK ===== >> "%LOG%"
)
type "%LOG%"
timeout /t 5 >nul
endlocal
