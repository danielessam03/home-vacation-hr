@echo off
setlocal EnableDelayedExpansion
title Home Vacation HR - laptop agent setup
cd /d "%~dp0"

rem ---- run elevated (needed to register the auto-start task) ----
net session >nul 2>&1
if errorlevel 1 (
  echo Asking Windows for permission to set up auto-start...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo  =====================================================
echo   Home Vacation HR - laptop presence agent setup
echo  =====================================================
echo.

rem ---- 1. Python ----
python --version >nul 2>&1
if errorlevel 1 (
  echo  Python is not installed. Installing Python 3.12 ...
  winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
  if errorlevel 1 (
    echo.
    echo  Could not install Python automatically.
    echo  Install it from https://www.python.org/downloads/windows/
    echo  ^(tick "Add python.exe to PATH"^) and then double-click install.bat again.
    pause
    exit /b 1
  )
  echo.
  echo  Python installed. Close this window and double-click install.bat once more.
  pause
  exit /b 0
)
python -m pip install --quiet --disable-pip-version-check requests
if errorlevel 1 (
  echo  Could not install the "requests" package. Check the internet connection and try again.
  pause
  exit /b 1
)

rem ---- 2. token ----
if exist agent_config.json (
  echo  agent_config.json already exists - keeping the existing token.
) else (
  echo  In the HR system open: Employees ^> this person ^> "Generate token", copy it,
  set /p TOKEN= then paste it here and press Enter:
  if "!TOKEN!"=="" (
    echo  No token entered. Run install.bat again when you have it.
    pause
    exit /b 1
  )
  > agent_config.json echo { "agent_token": "!TOKEN!" }
)

rem ---- 3. auto-start at every login ----
schtasks /Create /TN "HV HR presence agent" /TR "\"%~dp0run_agent.bat\"" /SC ONLOGON /F >nul
if errorlevel 1 (
  echo  Could not register auto-start. Right-click install.bat and choose "Run as administrator".
  pause
  exit /b 1
)

rem ---- 4. start now ----
start "" /min "%~dp0run_agent.bat"
echo.
echo  Done. The agent is running now and will start by itself at every login.
echo  It reports idle time only - no screenshots, no keystrokes.
echo.
pause
