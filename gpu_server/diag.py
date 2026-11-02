"""FitMe connection check: is the phone able to reach the laptop? Writes diag_log.txt."""
import json
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
disc = json.loads((ROOT / "discovery.json").read_text(encoding="utf-8"))
out = []


def log(*a):
    line = " ".join(str(x) for x in a)
    print(line, flush=True)
    out.append(line)


def get(url, key=False, timeout=15):
    req = urllib.request.Request(url, headers={"X-FitMe-Key": disc["key"]} if key else {})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(300).decode("utf-8", "replace")
            return f"HTTP {r.status} in {time.time() - t:.1f}s: {body[:160]}"
    except Exception as exc:
        return f"FAIL in {time.time() - t:.1f}s: {type(exc).__name__}: {str(exc)[:200]}"


log("time:", time.strftime("%Y-%m-%d %H:%M:%S"))
log("local backend :", get("http://127.0.0.1:8000/health"))
log("local GPU     :", get("http://127.0.0.1:7860/health"))
log("status file   :", (ROOT / "tunnel_status.txt").read_text(encoding="utf-8").replace("\n", " | "))

latest = None
try:
    with urllib.request.urlopen(f"https://ntfy.sh/{disc['topic']}/json?poll=1&since=12h", timeout=15) as r:
        for line in r.read().decode().splitlines():
            ev = json.loads(line)
            if ev.get("event") == "message":
                latest = json.loads(ev["message"])
    log("ntfy latest   :", latest, "age", int(time.time() - latest["ts"]) if latest else "-", "s")
except Exception as exc:
    log("ntfy          : FAIL", type(exc).__name__, exc)

if latest:
    if latest.get("lan"):
        log("LAN health    :", get(latest["lan"] + "/health", timeout=6))
    if latest.get("tunnel"):
        log("tunnel health :", get(latest["tunnel"] + "/health"))
        log("tunnel + key  :", get(latest["tunnel"] + "/api/v1/catalog", key=True))
        log("tunnel no key :", get(latest["tunnel"] + "/api/v1/catalog"))

for name in ("cloudflared.exe", "python.exe"):
    r = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {name}", "/NH"], capture_output=True, text=True)
    log(name, "processes:", sum(1 for l in r.stdout.splitlines() if name in l))

r = subprocess.run(["netsh", "wlan", "show", "interfaces"], capture_output=True, text=True, errors="replace")
for l in r.stdout.splitlines():
    if any(k in l for k in ("SSID", "State", "Состояние", "Profile", "Профиль")) and "BSSID" not in l:
        log("wifi          :", l.strip())
(ROOT / "diag_log.txt").write_text("\n".join(out) + "\n", encoding="utf-8")
