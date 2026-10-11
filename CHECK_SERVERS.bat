@echo off
cd /d "%~dp0"
set "LOG=%~dp0servers_status.txt"
echo Servers status %DATE% %TIME% > "%LOG%"
echo ===== GPU 7860 ===== >> "%LOG%"
curl -s -m 5 http://127.0.0.1:7860/health >> "%LOG%" 2>&1 || echo GPU server OFFLINE >> "%LOG%"
echo. >> "%LOG%"
echo ===== backend 8000 ===== >> "%LOG%"
curl -s -m 15 http://127.0.0.1:8000/api/v1/ai/status >> "%LOG%" 2>&1 || echo backend OFFLINE >> "%LOG%"
echo. >> "%LOG%"
echo ===== listening ===== >> "%LOG%"
netstat -aon | findstr "LISTENING" | findstr ":7860 :8000" >> "%LOG%"
echo ===== adb ===== >> "%LOG%"
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" devices >> "%LOG%" 2>&1
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" reverse --list >> "%LOG%" 2>&1
"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" shell pm list packages com.fitme >> "%LOG%" 2>&1
type "%LOG%"
timeout /t 5 >nul
