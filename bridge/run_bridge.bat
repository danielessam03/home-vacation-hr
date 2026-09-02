@echo off
rem Home Vacation HR - runs the ZKTeco bridge once (Task Scheduler calls this every 5 minutes)
cd /d "%~dp0"
"C:\Users\Essam\AppData\Local\Programs\Python\Python312\python.exe" bridge.py >> bridge_run.log 2>&1
