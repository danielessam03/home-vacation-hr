# Laptop presence agent — setup (once per work laptop / PC)

The agent tells the HR system how long the computer has been idle (no mouse or
keyboard anywhere on Windows). Without it, idleness is only detected inside
the HR app tab. It reports **idle time only**: no screenshots, no keystrokes,
no window titles. One small request per minute; nothing else leaves the PC.

## Quick install (recommended)

1. Copy this `agent` folder to the computer, e.g. `C:\HV-Agent`.
2. In the HR system: **Employees → the person → Generate token** and copy it.
3. Double-click **`install.bat`**. Allow the Windows permission prompt, paste
   the token when asked, press Enter.

That's all. The installer installs Python if needed, writes
`agent_config.json`, registers auto-start at every login, and starts the
agent. A minimised console window stays open; that's normal.

If Python had to be installed, the window says so: close it and double-click
`install.bat` a second time.

## Manual install (if the installer can't run)

1. Install Python 3.12 from https://www.python.org/downloads/windows/ — tick
   **"Add python.exe to PATH"**. Then in Command Prompt: `pip install requests`
2. Create `agent_config.json` next to `presence_agent.py`:

```json
{ "agent_token": "PASTE_THE_TOKEN_HERE" }
```

3. Command Prompt **as Administrator**, in the folder:

```
schtasks /Create /TN "HV HR presence agent" /TR "\"%CD%\run_agent.bat\"" /SC ONLOGON /F
```

4. Double-click `run_agent.bat` to start it now.

## Checking it works

`agent.log` in the folder gets a line every minute. In HR, the employee's live
session shows a laptop icon once the agent has reported.

## Rules

- One token = one employee = one computer. Never reuse a token.
- HR can press **Generate token** again at any time; the old token stops
  working immediately, so re-run `install.bat` after deleting
  `agent_config.json` to use the new one.
- To remove: delete the scheduled task "HV HR presence agent" in Task
  Scheduler and delete the folder.
