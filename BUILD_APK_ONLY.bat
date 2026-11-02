@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "LOG=%~dp0apk_log.txt"
echo FitMe build APK only %DATE% %TIME% > "%LOG%"
set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" set "ADB=adb"
set "GPY=%~dp0gpu_server\.venv\Scripts\python.exe"

rem ---- one-time: 3D avatar draft is not used (three_js needs CMake 3.31) ----
if exist "lib\avatar_3d.dart" (
  if not exist "legacy" mkdir legacy
  move /Y "lib\avatar_3d.dart" "legacy\avatar_3d.dart.txt" >> "%LOG%" 2>&1
)

rem ---- key + discovery topic that are built into the app ----
for /f "usebackq delims=" %%K in (`"%GPY%" gpu_server\discovery_value.py key`) do set "FKEY=%%K"
for /f "usebackq delims=" %%T in (`"%GPY%" gpu_server\discovery_value.py topic`) do set "FTOPIC=%%T"
if not defined FKEY (
  echo ERROR: discovery.json - run INSTALL_LOCAL_GPU.bat first >> "%LOG%"
  goto :end
)
echo discovery topic: !FTOPIC! >> "%LOG%"

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
set "JAVA_HOME=!JDKDIR!"
call flutter config --jdk-dir="!JDKDIR!" >> "%LOG%" 2>&1

echo [1/3] Building APK...
echo ===== flutter build apk ===== >> "%LOG%"
call flutter build apk --release --dart-define=FITME_KEY=!FKEY! --dart-define=FITME_TOPIC=!FTOPIC! >> "%LOG%" 2>&1
if errorlevel 1 (
  echo ERROR: build failed >> "%LOG%"
  goto :end
)

copy /Y "build\app\outputs\flutter-apk\app-release.apk" "%~dp0FitMe.apk" >> "%LOG%" 2>&1
echo ===== APK READY: FitMe.apk ===== >> "%LOG%"
goto :end

:end
type "%LOG%"
echo.
echo Log: %LOG%
pause
endlocal
