@echo off
title Home Vacation HR - stop the fingerprint bridge on this PC
rem Run this on the OLD PC once the bridge works on the new 24/7 PC, so only one bridge runs.
schtasks /Change /TN "HV HR punch bridge" /DISABLE >nul 2>&1
if errorlevel 1 (
  echo  No bridge task found on this PC - nothing to do.
) else (
  echo  The bridge task on this PC is now disabled. The new PC does the work.
  echo  To turn it back on: Task Scheduler ^> "HV HR punch bridge" ^> Enable.
)
pause
