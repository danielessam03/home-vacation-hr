# Laptop presence agent — setup (once per work laptop / PC)

The agent tells the HR system how long the computer has been idle (no mouse or
keyboard anywhere on Windows). Without it, idleness is only detected inside
the HR app tab. It reports **idle time only**: no screenshots, no keystrokes,
no window titles. One small request per minute; nothing else leaves the PC.

## Install (3 steps, no administrator needed)

1. In the HR system open **Attendance → Check in → "Laptop agent"** and
   download both files: **the agent (zip)** and **your agent_config.json**.
   (HR can also do this from the employee's card.)
2. Extract the zip into a folder you will keep, e.g. `Documents\HV-Agent`,
   and put `agent_config.json` into that same folder.
3. Double-click **`install.bat`**.

That's all. The installer installs Python (for this Windows user) if needed,
registers auto-start at every login of this user, and starts the agent
quietly in the background (no window stays open).

If Python had to be installed, the window says so: close it and double-click
`install.bat` a second time.

No `agent_config.json`? The installer asks for the token instead — HR finds it
on the employee's card ("Generate token").

## Checking it works

- `agent.log` in the folder gets a line every minute (`200 …`).
- In HR, the employee's card and their Check-in tab show **"Agent last seen"**
  with the time of the last report (green when it is live).

## Rules

- One token = one employee = one computer. Never reuse a token.
- HR can press **Generate token** again at any time; the old token stops
  working immediately (the log then says TOKEN REJECTED). Download the new
  `agent_config.json`, replace the old one and double-click `install.bat` again.
- Moving the folder breaks the auto-start: run `install.bat` again from the
  new place.
- To remove: Task Scheduler → delete "HV HR presence agent", then delete the
  folder.

## Manual install (if the installer can't run)

1. Install Python 3.12 from https://www.python.org/downloads/windows/ — tick
   **"Add python.exe to PATH"**. Then in Command Prompt: `pip install requests`
2. Put `agent_config.json` next to `presence_agent.py` (from HR, or
   `{ "agent_token": "PASTE_THE_TOKEN_HERE" }`).
3. Command Prompt in the folder:

```
schtasks /Create /TN "HV HR presence agent" /TR "\"%CD%\run_agent.bat\"" /SC ONLOGON /RL LIMITED /F
```

4. Double-click `run_agent.bat` to start it now.
