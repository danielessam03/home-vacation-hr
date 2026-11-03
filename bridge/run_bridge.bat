@echo off
rem Home Vacation HR - runs the ZKTeco bridge once (Task Scheduler calls this every 5 minutes).
rem Works on any PC: finds Python on the PATH (installed by install.bat) or the Python launcher.
cd /d "%~dp0"
set "PY="
for /f "delims=" %%p in ('where python 2^>nul') do if not defined PY set "PY=%%p"
if not defined PY (
  where py >nul 2>&1 && set "PY=py -3"
)
if not defined PY (
  echo [%date% %time%] ERROR python not found - double-click install.bat >> bridge_run.log
  exit /b 1
)
%PY% bridge.py >> bridge_run.log 2>&1
