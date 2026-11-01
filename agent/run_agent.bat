@echo off
rem Home Vacation HR - laptop presence agent (runs quietly in the background, one request per minute).
rem The agent itself refuses to start twice, so this is safe to run again.
cd /d "%~dp0"
where pythonw >nul 2>&1
if errorlevel 1 (
  start "HV HR presence agent" /min python presence_agent.py
) else (
  start "" pythonw presence_agent.py
)
