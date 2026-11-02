@echo off
setlocal
cd /d "%~dp0"
set "LOG=%~dp0ui_check_log.txt"
echo UI check %DATE% %TIME% > "%LOG%"
echo ===== flutter analyze ===== >> "%LOG%"
call flutter analyze >> "%LOG%" 2>&1
echo ===== flutter test ===== >> "%LOG%"
call flutter test >> "%LOG%" 2>&1
echo ===== ui tour ===== >> "%LOG%"
call flutter test test_tour --update-goldens >> "%LOG%" 2>&1
echo ===== backend tests ===== >> "%LOG%"
backend\.venv\Scripts\python.exe -m pip install -q -r backend\requirements.txt pytest >> "%LOG%" 2>&1
backend\.venv\Scripts\python.exe -m pytest backend\tests -q -p no:cacheprovider >> "%LOG%" 2>&1
echo ===== DONE ===== >> "%LOG%"
endlocal
