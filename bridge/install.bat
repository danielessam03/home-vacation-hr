@echo off
setlocal EnableDelayedExpansion
title Home Vacation HR - fingerprint bridge setup
cd /d "%~dp0"

echo.
echo  =====================================================
echo   Home Vacation HR - fingerprint bridge setup
echo   (pulls punches from the ZKTeco device every 5 min)
echo  =====================================================
echo.

rem ---- 1. the config file with the device IP and the secret ----
if not exist bridge_config.json (
  echo  bridge_config.json is missing.
  echo  Copy it from the old bridge PC ^(C:\Users\Essam\home-vacation-hr\bridge\bridge_config.json^)
  echo  into this folder, then double-click install.bat again.
  pause
  exit /b 1
)
echo  bridge_config.json found.

rem ---- 2. Python (user install, no administrator needed) ----
set "PY="
for /f "delims=" %%p in ('where python 2^>nul') do if not defined PY set "PY=%%p"
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
echo  Installing the two packages the bridge needs ...
python -m pip install --quiet --disable-pip-version-check pyzk requests
if errorlevel 1 (
  echo  Could not install the packages. Check the internet connection and try again.
  pause
  exit /b 1
)

rem ---- 3. can this PC reach the device? ----
for /f "tokens=2 delims=:," %%a in ('findstr /i "device_ip" bridge_config.json') do set "DEVIP=%%~a"
set "DEVIP=%DEVIP:"=%"
set "DEVIP=%DEVIP: =%"
echo  Pinging the fingerprint device at %DEVIP% ...
ping -n 2 -w 1500 %DEVIP% >nul 2>&1
if errorlevel 1 (
  echo.
  echo  WARNING: the device %DEVIP% does not answer from this PC.
  echo  This PC must be on the same office network as the device ^(cable or office Wi-Fi^).
  echo  The task will still be created; fix the network and the next run will work.
  echo.
) else (
  echo  Device answers.
)

rem ---- 4. run every 5 minutes (no admin needed; runs while this user is logged in) ----
schtasks /Delete /TN "HV HR punch bridge" /F >nul 2>&1
schtasks /Create /TN "HV HR punch bridge" /TR "\"%~dp0run_bridge.bat\"" /SC MINUTE /MO 5 /F >nul
if errorlevel 1 (
  echo  Could not register the scheduled task. Copy this folder to C:\HV-Bridge and try again.
  pause
  exit /b 1
)
echo  Scheduled: "HV HR punch bridge" every 5 minutes.

rem ---- 5. run it once now and show the result ----
echo  Running the bridge once now ...
call run_bridge.bat
echo.
echo  Last lines of the log:
powershell -NoProfile -Command "Get-Content bridge_run.log -Tail 3"
echo.
echo  Done. If the last line says "device ok" or "sent N new punches", the bridge works.
echo  Keep this user logged in ^(the screen may be locked^). After a restart, log in once.
echo  On the OLD PC double-click disable_bridge_here.bat so only one bridge runs.
echo.
pause
