@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "LOG=%~dp0phone_log.txt"
set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=adb"
echo FitMe install FitMe.apk on every connected phone %DATE% %TIME% > "%LOG%"
"%ADB%" devices -l >> "%LOG%" 2>&1
set "N=0"
for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices 2^>nul') do (
  if "%%B"=="device" (
    set /a N+=1
    echo ===== %%A ===== >> "%LOG%"
    "%ADB%" -s %%A install -r "FitMe.apk" >> "%LOG%" 2>&1
    "%ADB%" -s %%A reverse tcp:8000 tcp:8000 >> "%LOG%" 2>&1
    "%ADB%" -s %%A shell am start -n com.fitme.fitme_ai/.MainActivity >> "%LOG%" 2>&1
  )
  if "%%B"=="unauthorized" echo %%A: unlock the phone and tap Allow USB debugging >> "%LOG%"
)
echo phones: !N! >> "%LOG%"
type "%LOG%"
pause
