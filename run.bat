@echo off
setlocal EnableExtensions
cd /d "%~dp0"

where powershell >nul 2>&1
if errorlevel 1 (
  echo ERROR: PowerShell not found on PATH.
  pause
  exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
  echo ERROR: git not found. Install Git for Windows first.
  pause
  exit /b 1
)

where gh >nul 2>&1
if errorlevel 1 (
  echo ERROR: GitHub CLI ^(gh^) not found. Install from https://cli.github.com/
  pause
  exit /b 1
)

echo.
echo === tool-xcode-ipa-github ===
echo Place ONE .zip in Xcode-Input\ then this script will:
echo   1^) detect project
echo   2^) upload zip to GitHub Release
echo   3^) build IPA on GitHub Actions
echo   4^) download IPA to Xcode-Output\
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
set ERR=%ERRORLEVEL%

echo.
if not "%ERR%"=="0" (
  echo FAILED. See messages above.
  pause
  exit /b %ERR%
)

pause
exit /b 0
