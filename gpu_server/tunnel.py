"""FitMe wireless access: Cloudflare quick tunnel + address announcement for the phone app.

What it does (runs in its own window while you use FitMe):
  1. starts `cloudflared tunnel --url http://127.0.0.1:8000` (like the Kaggle notebook) and
     reads the public https://....trycloudflare.com address;
  2. finds the laptop's Wi-Fi address (for fast access at home);
  3. every few minutes publishes both addresses to a private ntfy.sh topic, so the phone app
     finds the server by itself - no cable and no typing of addresses.

The topic name and the access key live in discovery.json (created once, never committed).
The key itself is NOT published - it is built into the APK and checked by the backend.
"""
from __future__ import annotations

import json
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DISCOVERY = ROOT / "discovery.json"
STATUS = ROOT / "tunnel_status.txt"
CLOUDFLARED = ROOT / "tools" / "cloudflared.exe"
BACKEND = "http://127.0.0.1:8000"
NTFY = "https://ntfy.sh"
REPUBLISH_SEC = 10 * 60


def load_discovery() -> dict:
    if DISCOVERY.exists():
        return json.loads(DISCOVERY.read_text(encoding="utf-8"))
    data = {"topic": "fitme-" + secrets.token_hex(12), "key": secrets.token_urlsafe(24)}
    DISCOVERY.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return data


def lan_ip() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        return None if ip.startswith("127.") else ip
    except OSError:
        return None


def publish(topic: str, payload: dict) -> bool:
    req = urllib.request.Request(
        f"{NTFY}/{topic}",
        data=json.dumps(payload).encode(),
        headers={"Title": "fitme-server", "Tags": "fitme"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status == 200
    except Exception as exc:  # network hiccup - try again next round
        print("publish failed:", exc)
        return False


def write_status(lines: list[str]) -> None:
    STATUS.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_tunnel(state: dict) -> None:
    """Start cloudflared, keep restarting it if it dies, update state['tunnel']."""
    while True:
        proc = subprocess.Popen(
            [str(CLOUDFLARED), "tunnel", "--url", BACKEND, "--no-autoupdate"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        for line in proc.stdout:
            m = re.search(r"https://[-a-z0-9]+\.trycloudflare\.com", line)
            if m and state.get("tunnel") != m.group(0):
                state["tunnel"] = m.group(0)
                state["changed"].set()
        proc.wait()
        state["tunnel"] = None
        print("cloudflared stopped, restarting in 5 s...")
        time.sleep(5)


def main() -> None:
    if not CLOUDFLARED.exists():
        sys.exit(f"cloudflared not found: {CLOUDFLARED} (run START_LOCAL_GPU.bat)")
    disc = load_discovery()
    state: dict = {"tunnel": None, "changed": threading.Event()}
    threading.Thread(target=run_tunnel, args=(state,), daemon=True).start()

    print("Waiting for Cloudflare tunnel...")
    state["changed"].wait(90)
    while True:
        ip = lan_ip()
        lan = f"http://{ip}:8000" if ip else None
        payload = {"lan": lan, "tunnel": state.get("tunnel"), "ts": int(time.time())}
        ok = publish(disc["topic"], payload)
        lines = [
            f"updated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            f"wifi:    {lan or '-'}",
            f"tunnel:  {state.get('tunnel') or 'not ready'}",
            f"announced to phone app: {'yes' if ok else 'FAILED (no internet?)'}",
        ]
        write_status(lines)
        print("\n".join(lines), "\n")
        state["changed"].clear()
        state["changed"].wait(REPUBLISH_SEC)


if __name__ == "__main__":
    main()
