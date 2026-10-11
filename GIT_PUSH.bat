@echo off
setlocal
cd /d "%~dp0"
set "BR=fitme-cloud-benchmark"
set "FORK=https://github.com/BAKKAR06/fitme-ai.git"
set "LOG=%~dp0git_push_log.txt"
echo FitMe git push %DATE% %TIME% > "%LOG%"

rem --- author identity only for this repo (not global) ---
git config user.email >nul 2>&1
if errorlevel 1 (
  git config user.name "Bakdaulet Karabaev"
  git config user.email "karabaevbakdaulet16@gmail.com"
)

rem --- remote "bakkar06" = your fork; origin (Vireyx) is not changed ---
git remote get-url bakkar06 >nul 2>&1
if errorlevel 1 git remote add bakkar06 %FORK% >> "%LOG%" 2>&1
git remote -v >> "%LOG%" 2>&1

echo ===== branch %BR% ===== >> "%LOG%"
git rev-parse --verify %BR% >nul 2>&1
if errorlevel 1 (
  git checkout -b %BR% >> "%LOG%" 2>&1
) else (
  git checkout %BR% >> "%LOG%" 2>&1
)
if errorlevel 1 goto :fail
git branch --show-current >> "%LOG%" 2>&1

echo ===== commit ===== >> "%LOG%"
git rm --cached -q --ignore-unmatch git_push_log.txt check_log.txt >nul 2>&1
git add -A >> "%LOG%" 2>&1
git diff --cached --quiet
if errorlevel 1 if exist "commit_msg.txt" (
  git commit -F commit_msg.txt >> "%LOG%" 2>&1
  if errorlevel 1 goto :fail
  del commit_msg.txt
  goto :committed
)
git diff --cached --quiet
if errorlevel 1 (
  git commit -m "Cloud mode, model benchmark kit, Android and backend fixes" -m "- backend: free Hugging Face Space provider (FASHN on ZeroGPU), auto fallback Kaggle/HF, Pillow dependency, Dockerfile for HF Spaces" -m "- android: INTERNET permission for release APK; app polling survives network drops; analyzer clean, tests pass" -m "- benchmark/: HF Spaces runner, auto evaluation, Kaggle notebook; docs/ report; BUILD_APK.bat, CHECK_PROJECT.bat, DEPLOY_CLOUD.md" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_017zSqzGDXxDEhHmDrZ3xsRi" >> "%LOG%" 2>&1
  if errorlevel 1 goto :fail
) else (
  echo nothing new to commit >> "%LOG%"
)
:committed
rem --- keep log files out of the (not yet pushed) commit ---
git ls-files --error-unmatch git_push_log.txt >nul 2>&1
if not errorlevel 1 (
  git rm --cached -q git_push_log.txt >> "%LOG%" 2>&1
  git commit --amend --no-edit >> "%LOG%" 2>&1
)
git log --oneline -3 >> "%LOG%" 2>&1

echo ===== push %BR% to your fork (Vireyx/main is not touched) ===== >> "%LOG%"
git push -u bakkar06 %BR% >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo ===== OK ===== >> "%LOG%"
type "%LOG%"
echo.
echo Done. Open https://github.com/BAKKAR06/fitme-ai/tree/%BR%
pause
exit /b 0

:fail
echo ===== FAILED ===== >> "%LOG%"
type "%LOG%"
echo.
echo Push failed - see git_push_log.txt. If a GitHub sign-in window appeared, sign in as BAKKAR06 and run this file again.
pause
exit /b 1
