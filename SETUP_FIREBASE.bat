@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo  FitMe accounts live in YOUR Firebase project (free plan).
echo  Before this, do the steps from FIREBASE_SETUP.md:
echo   - create the project, turn on Email/Password sign-in, create Firestore
echo   - save the service-account key as backend\data\firebase-service-account.json
echo.
set "APIKEY="
set /p "APIKEY=Web API key (Project settings - General): "
if "%APIKEY%"=="" goto :eof
backend\.venv\Scripts\python.exe -m pip install -q -r backend\requirements.txt
pushd backend
.venv\Scripts\python.exe -m app.setup_firebase "%APIKEY%"
popd
echo.
pause
