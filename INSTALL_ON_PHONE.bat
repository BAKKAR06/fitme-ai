@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "LOG=%~dp0phone_log.txt"
echo FitMe install on phone %DATE% %TIME% > "%LOG%"
set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=adb"

echo ===== servers ===== >> "%LOG%"
curl -s -m 5 http://127.0.0.1:7860/health >> "%LOG%" 2>&1 || echo GPU server OFFLINE >> "%LOG%"
echo. >> "%LOG%"
curl -s -m 15 http://127.0.0.1:8000/api/v1/ai/status >> "%LOG%" 2>&1 || echo backend OFFLINE >> "%LOG%"
echo. >> "%LOG%"

rem ---- one-time: 3D avatar draft is not used; three_js broke the APK build (needs CMake) ----
if exist "lib\avatar_3d.dart" (
  if not exist "legacy" mkdir legacy
  move /Y "lib\avatar_3d.dart" "legacy\avatar_3d.dart.txt" >> "%LOG%" 2>&1
)

rem ---- GPU server: start it if it is not answering ----
curl -s -m 5 http://127.0.0.1:7860/health >nul 2>&1
if errorlevel 1 (
  echo starting GPU server... >> "%LOG%"
  start "FitMe GPU (FASHN)" /D "%~dp0gpu_server" cmd /k .venv\Scripts\python.exe fashn_server.py
)

rem ---- backend: start it if it is not answering ----
curl -s -m 5 http://127.0.0.1:8000/health >nul 2>&1
if errorlevel 1 (
  echo starting backend... >> "%LOG%"
  set "FITME_REMOTE_AI_URL=http://127.0.0.1:7860"
  set "FITME_AI_PROVIDER=kaggle"
  set "FITME_FASHN_STEPS=20"
  start "FitMe Backend" /D "%~dp0backend" cmd /k .venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
  timeout /t 8 >nul
  curl -s -m 15 http://127.0.0.1:8000/api/v1/ai/status >> "%LOG%" 2>&1 || echo backend still OFFLINE >> "%LOG%"
  echo. >> "%LOG%"
)

rem ---- Java (JDK 21) for Android build: portable copy inside the project ----
echo ===== JDK ===== >> "%LOG%"
set "JDKDIR="
for /d %%J in ("%~dp0tools\jdk-21*") do set "JDKDIR=%%~fJ"
if not defined JDKDIR (
  echo Downloading JDK 21 - Eclipse Temurin, about 190 MB...
  if not exist "%~dp0tools" mkdir "%~dp0tools"
  powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse' -OutFile '%~dp0tools\jdk21.zip'; Expand-Archive '%~dp0tools\jdk21.zip' -DestinationPath '%~dp0tools' -Force; Remove-Item '%~dp0tools\jdk21.zip'" >> "%LOG%" 2>&1
  for /d %%J in ("%~dp0tools\jdk-21*") do set "JDKDIR=%%~fJ"
)
if not defined JDKDIR (
  echo ERROR: JDK download failed >> "%LOG%"
  goto :end
)
echo JDK: !JDKDIR! >> "%LOG%"
"!JDKDIR!\bin\java.exe" -version >> "%LOG%" 2>&1
set "JAVA_HOME=!JDKDIR!"
call flutter config --jdk-dir="!JDKDIR!" >> "%LOG%" 2>&1

echo ===== adb devices ===== >> "%LOG%"
"%ADB%" devices -l >> "%LOG%" 2>&1
set "DEVICE="
for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices 2^>nul') do (
  if "%%B"=="device" if not defined DEVICE set "DEVICE=%%A"
)
if not defined DEVICE (
  echo ERROR: phone not authorized/connected. Unlock the phone and accept "Allow USB debugging". >> "%LOG%"
  goto :end
)
"%ADB%" -s !DEVICE! reverse tcp:8000 tcp:8000 >> "%LOG%" 2>&1

echo [1/3] Building APK (first build 3-10 min)...
echo ===== flutter build apk ===== >> "%LOG%"
call flutter build apk --release >> "%LOG%" 2>&1
if errorlevel 1 (
  echo ERROR: build failed >> "%LOG%"
  goto :end
)

echo [2/3] Installing on phone (confirm on the phone if asked)...
echo ===== adb install ===== >> "%LOG%"
"%ADB%" -s !DEVICE! install -r "build\app\outputs\flutter-apk\app-release.apk" >> "%LOG%" 2>&1
if errorlevel 1 (
  echo ERROR: install failed >> "%LOG%"
  goto :end
)

echo [3/3] Starting app...
echo ===== start ===== >> "%LOG%"
"%ADB%" -s !DEVICE! shell am start -n com.fitme.fitme_ai/.MainActivity >> "%LOG%" 2>&1
echo ===== DONE ===== >> "%LOG%"

:end
type "%LOG%"
echo.
echo Log: %LOG%
pause
endlocal
