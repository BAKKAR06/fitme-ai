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
import os
import re
import secrets
import shutil
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

# Watchdog: if the GPU server or the backend window is closed or crashes, start it again
# (the phone otherwise sees the tunnel answer "530" and shows "no connection").
# Environment variables (FITME_API_KEY, FITME_REMOTE_AI_URL, ...) are inherited from START_LOCAL_GPU.bat.
SERVERS = {
    "backend": {
        "health": BACKEND + "/health",
        "title": "FitMe Backend",
        "dir": ROOT / "backend",
        "cmd": r".venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000",
        "cooldown": 60,
    },
    "gpu": {
        "health": "http://127.0.0.1:7860/health",
        "title": "FitMe GPU (FASHN)",
        "dir": ROOT / "gpu_server",
        "cmd": r".venv\Scripts\python.exe fashn_server.py",
        "cooldown": 300,  # the model needs 1-2 minutes to load
    },
}


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


def alive(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            return r.status == 200
    except Exception:
        return False


def watchdog(state: dict) -> None:
    misses = {name: 0 for name in SERVERS}
    last_start = {name: time.time() for name in SERVERS}  # START_LOCAL_GPU.bat just started them
    while True:
        time.sleep(20)
        for name, srv in SERVERS.items():
            if alive(srv["health"]):
                misses[name] = 0
                state["servers"][name] = "ok"
                continue
            misses[name] += 1
            state["servers"][name] = "down"
            if misses[name] >= 2 and time.time() - last_start[name] > srv["cooldown"]:
                print(f"{time.strftime('%H:%M:%S')} {name} is not answering - starting it again")
                subprocess.Popen(
                    f'start "{srv["title"]}" /D "{srv["dir"]}" cmd /k {srv["cmd"]}',
                    shell=True,
                )
                last_start[name] = time.time()
                misses[name] = 0
                state["restarts"] += 1
                state["changed"].set()


def write_status(lines: list[str]) -> None:
    STATUS.write_text("\n".join(lines) + "\n", encoding="utf-8")


def tunnel_candidates():
    """Ways to expose the backend to the internet, tried in order.

    Cloudflare needs outbound port 7844 (QUIC/UDP, or TCP with http2). Some networks
    (university / office Wi-Fi) block it - then the fallback is Pinggy over SSH on port 443,
    which looks like normal HTTPS traffic (free tunnels last 60 minutes, then reconnect)."""
    cf = [str(CLOUDFLARED), "tunnel", "--url", BACKEND, "--no-autoupdate"]
    cf_url = r"https://[-a-z0-9]+\.trycloudflare\.com"
    yield "cloudflare", cf, cf_url
    yield "cloudflare-http2", cf + ["--protocol", "http2"], cf_url
    if shutil.which("ssh"):
        yield "pinggy-443", [
            "ssh", "-p", "443", "-T",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL",
            "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes",
            "-R", "0:127.0.0.1:8000", "free.pinggy.io",
        ], r"https://[-a-z0-9.]+\.(?:free\.pinggy\.net|pinggy-free\.link|pinggy\.link)"


PREF = ROOT / "tools" / "tunnel_pref.txt"


def ordered_candidates():
    """The way that worked last time is tried first (e.g. Pinggy on university Wi-Fi)."""
    items = list(tunnel_candidates())
    last = PREF.read_text(encoding="utf-8").strip() if PREF.exists() else ""
    return sorted(items, key=lambda it: 0 if it[0] == last else 1)


def ssh_env() -> dict:
    """Pinggy asks for a password - an empty one is fine; give it without a console prompt."""
    ask = ROOT / "tools" / "empty_pass.bat"
    if not ask.exists():
        ask.write_text("@echo.\r\n", encoding="ascii")
    return dict(os.environ, SSH_ASKPASS=str(ask), SSH_ASKPASS_REQUIRE="force", DISPLAY="x")


def public_ok(url: str) -> bool:
    try:
        with urllib.request.urlopen(url + "/health", timeout=10) as r:
            return r.status == 200 and b"FitMe AI" in r.read(400)
    except Exception:
        return False


def run_one(state: dict, name: str, cmd: list[str], pattern: str) -> None:
    """Runs one tunnel while it really works from the internet; returns when it does not."""
    print(f"{time.strftime('%H:%M:%S')} starting tunnel: {name}")
    try:
        proc = subprocess.Popen(
            cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", env=ssh_env() if cmd[0] == "ssh" else None,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except OSError as exc:
        print(f"{name}: cannot start ({exc})")
        return
    found: dict = {}
    ready = threading.Event()

    def reader():
        for line in proc.stdout:
            m = re.search(pattern, line)
            if m and "url" not in found:
                found["url"] = m.group(0)
                ready.set()

    threading.Thread(target=reader, daemon=True).start()
    try:
        if not ready.wait(30):
            print(f"{name}: no address in 30 s")
            return
        url = found["url"]
        deadline = time.time() + 30
        while not public_ok(url):
            if time.time() > deadline or proc.poll() is not None:
                print(f"{name}: {url} is not reachable from the internet (network blocks it?)")
                return
            time.sleep(4)
        state["tunnel"], state["tunnel_kind"] = url, name
        try:
            PREF.write_text(name, encoding="utf-8")
        except OSError:
            pass
        state["changed"].set()
        print(f"{time.strftime('%H:%M:%S')} tunnel OK via {name}: {url}")
        misses = 0
        while proc.poll() is None:
            time.sleep(45)
            misses = 0 if public_ok(url) else misses + 1
            if misses >= 3:
                print(f"{name}: stopped answering, switching")
                return
    finally:
        if proc.poll() is None:
            proc.kill()
        if state.get("tunnel") == found.get("url"):
            state["tunnel"] = None
            state["changed"].set()


def run_tunnel(state: dict) -> None:
    while True:
        for name, cmd, pattern in ordered_candidates():
            run_one(state, name, cmd, pattern)
        time.sleep(5)


def main() -> None:
    if not CLOUDFLARED.exists():
        sys.exit(f"cloudflared not found: {CLOUDFLARED} (run START_LOCAL_GPU.bat)")
    disc = load_discovery()
    state: dict = {"tunnel": None, "tunnel_kind": None, "changed": threading.Event(), "servers": {}, "restarts": 0}
    threading.Thread(target=run_tunnel, args=(state,), daemon=True).start()
    if sys.platform == "win32":
        threading.Thread(target=watchdog, args=(state,), daemon=True).start()

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
            f"tunnel:  {state.get('tunnel') or 'not ready'} ({state.get('tunnel_kind') or '-'})",
            f"announced to phone app: {'yes' if ok else 'FAILED (no internet?)'}",
            f"servers: {state['servers'] or 'checking'}; auto-restarts: {state['restarts']}",
        ]
        write_status(lines)
        print("\n".join(lines), "\n")
        state["changed"].clear()
        state["changed"].wait(REPUBLISH_SEC)


if __name__ == "__main__":
    main()
