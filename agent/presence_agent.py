"""
Home Vacation HR - laptop presence agent
-----------------------------------------
Reports the laptop's real idle time (seconds since the last keyboard or
mouse input anywhere on the system) to the HR system every minute, so
"are you still working?" prompts are based on actual laptop activity, not
just the HR browser tab.

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
FUNCTION_URL = "https://plwyzkqlbzcikmuurjqg.supabase.co/functions/v1/presence"
INTERVAL_SECONDS = 60


class LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]


def idle_seconds() -> float:
    """Windows: seconds since the last user input on the whole system."""
    info = LASTINPUTINFO()
    info.cbSize = ctypes.sizeof(LASTINPUTINFO)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
        return 0.0
    millis = ctypes.windll.kernel32.GetTickCount() - info.dwTime
    return max(0.0, millis / 1000.0)


def main() -> int:
    if not os.path.exists(CFG_PATH):
        print("agent_config.json missing -- copy the employee's agent token from HR into it.")
        return 1
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    token = cfg.get("agent_token", "").strip()
    url = cfg.get("function_url", FUNCTION_URL)
    if not token:
        print("agent_token is empty in agent_config.json")
        return 1

    while True:
        try:
            r = requests.post(url, json={"idle_seconds": round(idle_seconds())},
                              headers={"x-agent-token": token}, timeout=20)
            print(time.strftime("%H:%M:%S"), r.status_code, r.text[:120])
        except Exception as e:  # noqa: BLE001 - keep running through network blips
            print(time.strftime("%H:%M:%S"), "ERROR", e)
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
