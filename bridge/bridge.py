"""
Home Vacation HR - ZKTeco TX628 attendance bridge
--------------------------------------------------
Pulls punches from the TX628 on the local network (pyzk, port 4370),
dedupes against a local state file, and POSTs new punches to the
Supabase Edge Function /punch secured with a shared secret.

Run it every 5 minutes via Task Scheduler (see run_bridge.bat and
README.md in this folder).

Setup once:
    pip install pyzk requests
"""

import json
import os
import sys
from datetime import datetime

import requests
from zk import ZK

# ----------------------------------------------------------------------
# CONFIG -- defaults; overridden by bridge_config.json in this folder
# (bridge_config.json is git-ignored so the secret never enters git).
# ----------------------------------------------------------------------
DEVICE_IP = "192.168.1.201"          # TX628 IP on your office network
DEVICE_PORT = 4370
DEVICE_PASSWORD = 0                  # COMM key set on the device (0 = none)
FUNCTION_URL = "https://plwyzkqlbzcikmuurjqg.supabase.co/functions/v1/punch"
PUNCH_SECRET = "PUT_A_LONG_RANDOM_SECRET_HERE"   # must equal the PUNCH_SECRET edge-function secret

DEVICE_ID = "tx628-hq"               # label stored with every punch

_cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge_config.json")
if os.path.exists(_cfg_path):
    with open(_cfg_path, "r", encoding="utf-8") as _f:
        _cfg = json.load(_f)
    DEVICE_IP = _cfg.get("device_ip", DEVICE_IP)
    DEVICE_PORT = int(_cfg.get("device_port", DEVICE_PORT))
    DEVICE_PASSWORD = int(_cfg.get("device_password", DEVICE_PASSWORD))
    FUNCTION_URL = _cfg.get("function_url", FUNCTION_URL)
    PUNCH_SECRET = _cfg.get("punch_secret", PUNCH_SECRET)
    DEVICE_ID = _cfg.get("device_id", DEVICE_ID)
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge_state.json")
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge.log")
BATCH_SIZE = 500
# ----------------------------------------------------------------------


def log(msg: str) -> None:
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_state() -> dict:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"last_punch": "1970-01-01T00:00:00"}


def save_state(state: dict) -> None:
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f)


def main() -> int:
    state = load_state()
    last_seen = datetime.fromisoformat(state["last_punch"])

    zk = ZK(DEVICE_IP, port=DEVICE_PORT, timeout=15, password=DEVICE_PASSWORD)
    conn = None
    try:
        conn = zk.connect()
        conn.disable_device()
        records = conn.get_attendance() or []
    except Exception as e:  # noqa: BLE001 - report any device failure
        log(f"ERROR talking to device {DEVICE_IP}:{DEVICE_PORT} -> {e}")
        return 1
    finally:
        if conn:
            try:
                conn.enable_device()
                conn.disconnect()
            except Exception:  # noqa: BLE001
                pass

    # keep only punches newer than what we already sent
    fresh = [r for r in records if r.timestamp > last_seen]
    if not fresh:
        log(f"device ok, {len(records)} records on device, nothing new")
        return 0

    punches = [
        {
            "employee_device_code": str(r.user_id),
            # device clock is local time; astimezone() stamps this PC/device timezone
            "punch_time": r.timestamp.astimezone().isoformat(),
            # TX628 punch codes: 0=check-in, 1=check-out (others -> unknown)
            "direction": {0: "in", 1: "out"}.get(getattr(r, "punch", None), "unknown"),
            "device_id": DEVICE_ID,
        }
        for r in sorted(fresh, key=lambda r: r.timestamp)
    ]

    sent = 0
    for i in range(0, len(punches), BATCH_SIZE):
        batch = punches[i : i + BATCH_SIZE]
        resp = requests.post(
            FUNCTION_URL,
            json={"punches": batch},
            headers={"x-punch-secret": PUNCH_SECRET},
            timeout=30,
        )
        if resp.status_code != 200:
            log(f"ERROR upload failed HTTP {resp.status_code}: {resp.text[:300]}")
            return 1
        sent += len(batch)

    # server dedupes too (unique index), so advancing state is safe
    state["last_punch"] = max(r.timestamp for r in fresh).isoformat()
    save_state(state)
    log(f"sent {sent} new punches, state advanced to {state['last_punch']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
