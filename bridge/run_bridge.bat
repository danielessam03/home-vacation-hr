@echo off
rem Home Vacation HR - runs the ZKTeco bridge once (Task Scheduler calls this every 5 minutes).
rem Uses HV-Bridge.exe when it is in this folder (no Python needed); otherwise falls back to Python.
cd /d "%~dp0"
if exist "%~dp0HV-Bridge.exe" (
  "%~dp0HV-Bridge.exe" >> bridge_run.log 2>&1
  exit /b %errorlevel%
)
set "PY="
for /f "delims=" %%p in ('where python 2^>nul') do if not defined PY set "PY=%%p"
if not defined PY (
  where py >nul 2>&1 && set "PY=py -3"
)
if not defined PY (
  echo [%date% %time%] ERROR neither HV-Bridge.exe nor python found - double-click install.bat >> bridge_run.log
  exit /b 1
)
%PY% bridge.py >> bridge_run.log 2>&1
