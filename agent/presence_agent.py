"""
Home Vacation HR - laptop presence agent
-----------------------------------------
Reports the laptop's real idle time (seconds since the last keyboard or
mouse input anywhere on the system) to the HR system every minute, so
"are you still working?" prompts are based on actual laptop activity, not
just the HR browser tab. It reports idle time ONLY: no screenshots, no
keystrokes, no window titles.

Install once per work laptop (see README.md). Needs only Python and
requests -- no pip packages with native code.
"""

import ctypes
import json
import os
import sys
import time

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(HERE, "agent_config.json")
LOG_PATH = os.path.join(HERE, "agent.log")
FUNCTION_URL = "https://plwyzkqlbzcikmuurjqg.supabase.co/functions/v1/presence"
INTERVAL_SECONDS = 60
LOG_MAX_BYTES = 512 * 1024      # the log is trimmed when it grows past this


class LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]


def idle_seconds() -> float:
    """Windows: seconds since the last user input on the whole system.
    GetTickCount wraps after 49.7 days (and reads negative after 24.8 days
    as a signed int), so the difference is taken modulo 2**32."""
    info = LASTINPUTINFO()
    info.cbSize = ctypes.sizeof(LASTINPUTINFO)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0.0
    kernel32 = ctypes.windll.kernel32
    kernel32.GetTickCount.restype = ctypes.c_uint32
    now_ms = kernel32.GetTickCount()
    millis = (now_ms - info.dwTime) & 0xFFFFFFFF
    return max(0.0, millis / 1000.0)


def log(line: str) -> None:
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            with open(LOG_PATH, "r", encoding="utf-8", errors="ignore") as f:
                tail = f.read()[-LOG_MAX_BYTES // 2:]
            with open(LOG_PATH, "w", encoding="utf-8") as f:
                f.write(tail)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + line + "\n")
    except Exception:  # noqa: BLE001 - logging must never stop the agent
        pass


def single_instance():
    """Only one agent per laptop: a local port works as the lock (released when the process dies)."""
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 47631))
        s.listen(1)
        return s
    except OSError:
        return None


def main() -> int:
    lock = single_instance()
    if lock is None:
        return 0          # already running
    if not os.path.exists(CFG_PATH):
        log("agent_config.json missing -- put the employee's agent_config.json from HR next to this file.")
        return 1
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    token = cfg.get("agent_token", "").strip()
    url = cfg.get("function_url", FUNCTION_URL)
    if not token:
        log("agent_token is empty in agent_config.json")
        return 1
    log("agent started")
    bad_token = 0
    while True:
        try:
            r = requests.post(url, json={"idle_seconds": round(idle_seconds())},
                              headers={"x-agent-token": token}, timeout=20)
            log(f"{r.status_code} {r.text[:120]}")
            if r.status_code == 403:
                bad_token += 1
                if bad_token in (1, 10, 60):
                    log("TOKEN REJECTED: HR must generate a new token for this person; replace agent_config.json and run install.bat again.")
            else:
                bad_token = 0
        except Exception as e:  # noqa: BLE001 - keep running through network blips
            log(f"ERROR {e}")
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
