@echo off
rem Home Vacation HR - runs the ZKTeco bridge once.
rem Task Scheduler calls this every 5 minutes (see README.md).
cd /d "%~dp0"
python bridge.py >> bridge_run.log 2>&1
