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

## Moving the bridge to another PC (the 24/7 computer)

The bridge can run on any Windows PC that is **on the same office network as
the device** and stays on. Only ONE PC should run it at a time (two would
not corrupt anything, the server skips duplicates, but one is enough).

1. On the old PC copy the whole folder `C:\Users\Essam\home-vacation-hr\bridge`
   to a USB stick (or the office share). It must include `bridge_config.json`
   (device IP + secret) and `bridge_state.json` (what was already sent).
   Do not send `bridge_config.json` over chat: it contains the secret.
2. On the new PC paste the folder as `C:\HV-Bridge` (any folder works, but keep
   it out of Downloads) and double-click **install.bat**. It installs Python
   for that user if needed, the two packages, pings the device, registers the
   task "HV HR punch bridge" every 5 minutes, and runs it once.
   If Python had to be installed, the window says so: close it and run
   install.bat a second time.
3. Check `bridge_run.log` in the new folder: the last line must say
   `device ok` or `sent N new punches`. Punches then show in the app under
   Attendance → Review within 5 minutes.
4. On the old PC double-click **disable_bridge_here.bat** (or Task Scheduler →
   "HV HR punch bridge" → Disable).
5. On the new PC: keep that Windows user logged in (locking the screen is fine)
   and set Power options so the PC never sleeps. After a restart someone must
   log in once; the task then continues.

Spare copy of these files (without the config): https://github.com/danielessam03/home-vacation-hr/raw/main/HV-Bridge.zip

### بالعربي باختصار
1. انسخ فولدر `bridge` كله من جهاز دانيال على فلاشة (لازم يكون فيه `bridge_config.json` و `bridge_state.json`).
2. على الجهاز الجديد حطه في `C:\HV-Bridge` ودوس مرتين على `install.bat` (لو ثبّت بايثون، اقفل وشغّله تاني).
3. افتح `bridge_run.log`: آخر سطر لازم يكون `device ok` أو `sent N new punches`.
4. على الجهاز القديم دوس مرتين على `disable_bridge_here.bat`.
5. الجهاز الجديد ما ينامش، ويفضل المستخدم مسجّل دخوله (القفل عادي).
