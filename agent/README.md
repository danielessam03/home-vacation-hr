# Laptop presence agent — setup (once per work laptop)

The agent tells the HR system how long the laptop has been idle (no mouse or
keyboard anywhere on Windows). Without it, idleness is only detected inside
the HR app tab.

1. Install Python 3.12 from https://www.python.org/downloads/windows/ — tick
   **"Add python.exe to PATH"**. Then in Command Prompt: `pip install requests`
2. Copy this `agent` folder to the laptop (e.g. `C:\HV-Agent`).
3. In the HR app: **Employees → the person → Enroll face / Agent token → Generate
   token** → copy it.
4. Create `agent_config.json` next to `presence_agent.py`:

```json
{ "agent_token": "PASTE_THE_TOKEN_HERE" }
```

5. Run it at every login (Command Prompt **as Administrator** in that folder):

```
schtasks /Create /TN "HV HR presence agent" /TR "\"%CD%\run_agent.bat\"" /SC ONLOGON /F
```

Then start it once now by double-clicking `run_agent.bat` (a console window
stays open in the background — minimize it). It sends one small request per
minute; nothing else leaves the laptop. It reports **idle time only** — no
screenshots, no keystrokes, no window titles.

Each token identifies one employee: never share a token between laptops.
HR can regenerate a token any time, which immediately disconnects the old one.
