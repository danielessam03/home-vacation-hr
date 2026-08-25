# ZKTeco TX628 bridge — Windows setup

This folder pulls fingerprint punches from the TX628 and sends them to the
HR system every 5 minutes. Do this once on the office PC that is on the
same network as the device.

## 1. Install Python (once)

1. Download Python 3.12 from https://www.python.org/downloads/windows/
2. Run the installer — **tick "Add python.exe to PATH"** — Install.
3. Open Command Prompt and run:

```
pip install pyzk requests
```

## 2. Deploy the edge function (once, in the Supabase dashboard)

1. Supabase Dashboard → **Edge Functions** → **Deploy new function**.
2. Name it exactly `punch`, paste the contents of
   `supabase/functions/punch/index.ts` from this repository, deploy.
3. Open the function → **Secrets** → add `PUNCH_SECRET` = a long random
   text (30+ characters, e.g. from https://www.random.org/strings/).

## 3. Configure the bridge (once)

Open `bridge.py` in Notepad and edit the CONFIG block:

- `DEVICE_IP` — the TX628's IP address. Find it on the device:
  Menu → Comm. → Ethernet. Give it a **fixed IP** (or a DHCP reservation
  in your router) so it never changes.
- `PUNCH_SECRET` — the exact same value you saved in step 2.
- `DEVICE_ID` — any label, e.g. `tx628-hq`. If you later add a second
  device, give it a different label.

Employee matching: each person's **device code** on the TX628 (their user
ID on the fingerprint machine) must be entered in their HR profile —
Employees → edit → "Device code".

## 4. Test it

Double-click `run_bridge.bat`. Then check `bridge.log` — you should see
either `sent N new punches` or `nothing new`. Punches appear in the app
under Attendance → Review.

## 5. Schedule it every 5 minutes (once)

Open Command Prompt **as Administrator** in this folder and run:

```
schtasks /Create /TN "HV HR punch bridge" /TR "\"%CD%\run_bridge.bat\"" /SC MINUTE /MO 5 /F
```

That's it. To check it is running: Task Scheduler → Task Scheduler Library
→ "HV HR punch bridge". To stop it: right-click → Disable.

## Troubleshooting

- **`ERROR talking to device`** — wrong IP, device off, or a firewall is
  blocking port 4370. Ping the device IP first.
- **`upload failed HTTP 403`** — the secret in `bridge.py` does not match
  the `PUNCH_SECRET` secret on the edge function.
- **Punches arrive but show no employee name** — the person's "Device
  code" in their HR profile is empty or doesn't match their user ID on
  the machine.
- Safe to re-run any time: both the bridge and the server skip
  duplicates automatically.
