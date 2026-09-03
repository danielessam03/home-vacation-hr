@echo off
rem Home Vacation HR - laptop presence agent (runs continuously, one request per minute)
cd /d "%~dp0"
python presence_agent.py >> agent.log 2>&1
