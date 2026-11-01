@echo off
setlocal EnableDelayedExpansion
title Home Vacation HR - laptop agent setup
cd /d "%~dp0"

echo.
echo  =====================================================
echo   Home Vacation HR - laptop presence agent setup
echo   (idle time only: no screenshots, no keystrokes)
echo  =====================================================
echo.

rem ---- 1. Python (user install, no administrator needed) ----
set "PY="
for /f "delims=" %%p in ('where pythonw 2^>nul') do if not defined PY set "PY=%%p"
if not defined PY (
  where python >nul 2>&1 && for /f "delims=" %%p in ('where python') do if not defined PY set "PY=%%p"
)
if not defined PY (
  echo  Python is not installed. Installing Python 3.12 for this user ...
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

rem ---- 2. token: agent_config.json from HR, or paste the token ----
if exist agent_config.json (
  echo  agent_config.json found - using it.
) else (
  echo  In the HR system the employee opens Attendance ^> Check in ^> "Laptop agent"
  echo  and downloads agent_config.json into this folder - OR paste the token here.
  set /p TOKEN= Token ^(or just press Enter if the file is already here^):
  if "!TOKEN!"=="" (
    echo  No token. Put agent_config.json in this folder or run install.bat again with the token.
    pause
    exit /b 1
  )
  > agent_config.json echo { "agent_token": "!TOKEN!" }
)

rem ---- 3. auto-start at every login of THIS user (no admin needed) ----
schtasks /Delete /TN "HV HR presence agent" /F >nul 2>&1
schtasks /Create /TN "HV HR presence agent" /TR "\"%~dp0run_agent.bat\"" /SC ONLOGON /RL LIMITED /F >nul
if errorlevel 1 (
  echo  Could not register auto-start. Copy this folder to Documents and try again,
  echo  or ask IT to run install.bat on this laptop.
  pause
  exit /b 1
)

rem ---- 4. start now (no window stays open) ----
taskkill /F /FI "WINDOWTITLE eq HV HR presence agent*" >nul 2>&1
start "" "%~dp0run_agent.bat"
echo.
echo  Done. The agent is running now and will start by itself at every login.
echo  Check: agent.log in this folder gets a line every minute.
echo.
pause
