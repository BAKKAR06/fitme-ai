"""Usage analytics and the admin API.

What is measured
  * every request: who, which endpoint, status, time, traffic in/out   -> usage_events
  * every try-on: user, model, GPU seconds, queue wait, result size     -> tryon_jobs
  * the laptop every 30 s: CPU, RAM, GPU load/VRAM/temperature, queue   -> system_samples

From that the overview estimates how many people can use FitMe at the same time: one GPU
makes one picture at a time, so the queue (M/D/1 model) is the real limit, not CPU or RAM.
"""
from __future__ import annotations

import csv
import io
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

from . import auth, db, store

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])

_usage_buffer: list[tuple] = []
_buffer_lock = threading.Lock()
_storage_cache: dict[str, Any] = {"at": 0.0, "value": None}
_dirs: dict[str, Path] = {}
_queue_counter: Callable[[], tuple[int, int]] = lambda: (0, 0)
_started = False

ID_SEGMENT = re.compile(r"/[0-9a-f]{8,}(?=/|$)")
STATIC_PREFIXES = ("/uploads/", "/generated/", "/catalog/")


def configure(dirs: dict[str, Path], queue_counter: Callable[[], tuple[int, int]]) -> None:
    global _dirs, _queue_counter
    _dirs = dirs
    _queue_counter = queue_counter


# ------------------------------------------------------------------ request log
def normalize_path(path: str) -> str:
    for prefix in STATIC_PREFIXES:
        if path.startswith(prefix):
            return prefix + "*"  # pictures: one bucket per folder, not one row per file name
    path = ID_SEGMENT.sub("/{id}", path)
    return re.sub(r"/users/[A-Za-z0-9]{20,}", "/users/{id}", path)[:120]


def record_request(user_id: str | None, method: str, path: str, status: int,
                   ms: float, bytes_in: int, bytes_out: int) -> None:
    with _buffer_lock:
        _usage_buffer.append((time.time(), user_id, method, normalize_path(path), status, round(ms, 1),
                              int(bytes_in), int(bytes_out)))
        overflow = len(_usage_buffer) > 5000
    if overflow:
        flush_usage()


def flush_usage() -> int:
    with _buffer_lock:
        rows = list(_usage_buffer)
        _usage_buffer.clear()
    if rows:
        with db.transaction() as con:
            con.executemany(
                "INSERT INTO usage_events(ts, user_id, method, path, status, ms, bytes_in, bytes_out) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", rows)
    return len(rows)


# ------------------------------------------------------------------ machine load
def _nvidia_smi() -> dict[str, float]:
    exe = shutil.which("nvidia-smi")
    if not exe:
        return {}
    try:
        out = subprocess.run(
            [exe, "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,name",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.strip().splitlines()
        if not out:
            return {}
        parts = [p.strip() for p in out[0].split(",")]

        def num(value: str) -> float | None:
            try:
                return float(value)
            except ValueError:
                return None

        return {"gpu_util_pct": num(parts[0]), "vram_used_mb": num(parts[1]), "vram_total_mb": num(parts[2]),
                "gpu_temp_c": num(parts[3]), "gpu_power_w": num(parts[4]), "gpu_name": parts[5]}
    except Exception:
        return {}


def take_sample() -> dict[str, Any]:
    sample: dict[str, Any] = {"ts": time.time()}
    try:
        import psutil

        vm = psutil.virtual_memory()
        sample.update(
            cpu_pct=psutil.cpu_percent(interval=0.3),
            ram_used_mb=round((vm.total - vm.available) / 2**20),
            ram_total_mb=round(vm.total / 2**20),
            proc_rss_mb=round(psutil.Process().memory_info().rss / 2**20, 1),
        )
    except Exception:
        pass
    try:
        base = _dirs.get("base") or Path(".")
        sample["disk_free_gb"] = round(shutil.disk_usage(base).free / 2**30, 1)
    except Exception:
        pass
    gpu = _nvidia_smi()
    sample.update({k: v for k, v in gpu.items() if k != "gpu_name"})
    active, queued = _queue_counter()
    sample["active_jobs"], sample["queued_jobs"] = active, queued
    sample["online_users"] = online_users()
    return sample


def save_sample(sample: dict[str, Any]) -> None:
    cols = ["ts", "cpu_pct", "ram_used_mb", "ram_total_mb", "proc_rss_mb", "disk_free_gb", "gpu_util_pct",
            "vram_used_mb", "vram_total_mb", "gpu_temp_c", "gpu_power_w", "active_jobs", "queued_jobs", "online_users"]
    db.execute(f"INSERT OR REPLACE INTO system_samples({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
               tuple(sample.get(c) for c in cols))


def _purge_old() -> None:
    now = time.time()
    db.execute("DELETE FROM usage_events WHERE ts < ?", (now - 90 * 86400,))
    db.execute("DELETE FROM system_samples WHERE ts < ?", (now - 30 * 86400,))


def _loop() -> None:
    tick = 0
    while True:
        time.sleep(5)
        tick += 1
        try:
            flush_usage()
            if tick % 6 == 1:  # every 30 s
                save_sample(take_sample())
            if tick % 8640 == 2:  # twice a day
                _purge_old()
        except Exception as exc:  # analytics must never take the server down
            print(f"[FitMe] analytics: {type(exc).__name__}: {exc}")


def start_background() -> None:
    global _started
    if _started or os.getenv("FITME_SAMPLER", "1") == "0":
        return
    _started = True
    threading.Thread(target=_loop, daemon=True, name="fitme-analytics").start()


# ------------------------------------------------------------------ helpers
def online_users(window_s: int = 300) -> int:
    since = time.time() - window_s
    ids = {r["user_id"] for r in db.all_rows(
        "SELECT DISTINCT user_id FROM usage_events WHERE ts >= ? AND user_id IS NOT NULL", (since,))}
    with _buffer_lock:
        ids |= {row[1] for row in _usage_buffer if row[1] is not None and row[0] >= since}
    return len(ids)


def _folder_mb(path: Path | None) -> float:
    if path is None or not path.exists():
        return 0.0
    total = 0
    for entry in path.rglob("*"):
        try:
            if entry.is_file():
                total += entry.stat().st_size
        except OSError:
            pass
    return round(total / 2**20, 1)


def storage_summary(force: bool = False) -> dict[str, float]:
    if not force and _storage_cache["value"] and time.time() - _storage_cache["at"] < 600:
        return _storage_cache["value"]
    value = {name: _folder_mb(_dirs.get(name)) for name in ("uploads", "generated", "catalog")}
    db_path = _dirs.get("db")
    value["database"] = round(db_path.stat().st_size / 2**20, 1) if db_path and db_path.exists() else 0.0
    value["total"] = round(sum(value.values()), 1)
    _storage_cache.update(at=time.time(), value=value)
    return value


def _erlang_c(c: int, a: float) -> float:
    """Probability that a new try-on has to wait (M/M/c), a = offered load in GPUs."""
    term, total = 1.0, 1.0
    for k in range(1, c):
        term *= a / k
        total += term
    last = term * a / c / (1 - a / c)
    return last / (total + last)


def _wait(users: int, avg_job_s: float, think_s: float, gpus: int) -> float | None:
    """Mean queue wait, M/D/c (Allen-Cunneen: half of the M/M/c wait for fixed job times)."""
    a = users * avg_job_s / think_s
    if a >= gpus:
        return None
    return _erlang_c(gpus, a) * avg_job_s / (gpus - a) / 2


def capacity(avg_job_s: float, think_s: float, gpus: int = 1) -> dict[str, Any]:
    """Queue model: `gpus` cards, each try-on takes avg_job_s, an active person starts one every think_s."""
    gpus = max(1, gpus)
    rows = []
    for users in (1, 2, 3, 5, 8, 10, 15, 20, 30, 50):
        load = users * avg_job_s / think_s / gpus
        wait = _wait(users, avg_job_s, think_s, gpus)
        rows.append({"users": users, "load_pct": round(load * 100),
                     "wait_s": None if wait is None else round(wait), "overloaded": wait is None})

    def max_users(max_wait: float) -> int:
        best = 0
        for n in range(1, 2000):
            wait = _wait(n, avg_job_s, think_s, gpus)
            if wait is None or wait > max_wait:
                break
            best = n
        return best

    return {
        "gpus": gpus,
        "avg_job_s": round(avg_job_s, 1),
        "think_s": round(think_s),
        "per_hour": int(3600 * gpus // max(avg_job_s, 1)),
        "per_day": int(86400 * gpus // max(avg_job_s, 1)),
        "users_wait_30s": max_users(30),
        "users_wait_60s": max_users(60),
        "users_wait_120s": max_users(120),
        "table": rows,
    }


def _measured_job_seconds() -> tuple[float, int]:
    since = time.time() - 14 * 86400
    row = db.one(
        "SELECT AVG(gpu_seconds) AS avg, COUNT(*) AS n FROM tryon_jobs "
        "WHERE status = 'completed' AND gpu_seconds > 0 AND created_at >= ?",
        (since,))
    if row and row["n"]:
        return float(row["avg"]), int(row["n"])
    return 55.0, 0  # measured on the RTX 4060 laptop (30 steps + upscale)


def _measured_think_seconds() -> tuple[float, int]:
    """Median gap between two try-ons of the same person within 30 minutes."""
    since = time.time() - 14 * 86400
    rows = db.all_rows("SELECT user_id, created_at FROM tryon_jobs WHERE created_at >= ? AND user_id IS NOT NULL "
                       "ORDER BY user_id, created_at", (since,))
    gaps = []
    for prev, cur in zip(rows, rows[1:]):
        if prev["user_id"] == cur["user_id"]:
            gap = cur["created_at"] - prev["created_at"]
            if 5 < gap < 1800:
                gaps.append(gap)
    if len(gaps) >= 5:
        gaps.sort()
        return float(gaps[len(gaps) // 2]), len(gaps)
    return 180.0, len(gaps)  # assumption until there is data: one try-on every 3 minutes


def _workers() -> list[dict[str, Any]]:
    from .workers import POOL

    return POOL.snapshot()


def _gpus_online() -> int:
    from .workers import POOL

    return POOL.count()


# ------------------------------------------------------------------ endpoints
@router.get("/overview")
def overview(request: Request):
    auth.require_role(request, "admin")
    flush_usage()
    now = time.time()
    day, week = now - 86400, now - 7 * 86400
    latest = take_sample()
    jobs_day = db.one(
        "SELECT COUNT(*) AS n, SUM(status = 'completed') AS ok, SUM(status = 'failed') AS failed, "
        "SUM(gpu_seconds) AS gpu, AVG(CASE WHEN started_at IS NOT NULL THEN started_at - created_at END) AS wait "
        "FROM tryon_jobs WHERE created_at >= ?", (day,)) or {}
    avg_job, measured_jobs = _measured_job_seconds()
    think, measured_gaps = _measured_think_seconds()
    traffic_day = db.one("SELECT COUNT(*) AS requests, SUM(bytes_in) AS bin, SUM(bytes_out) AS bout, AVG(ms) AS ms "
                         "FROM usage_events WHERE ts >= ?", (day,)) or {}
    hourly = db.all_rows(
        "SELECT CAST((created_at - ?) / 3600 AS INTEGER) AS h, COUNT(*) AS n FROM tryon_jobs "
        "WHERE created_at >= ? GROUP BY h", (day, day))
    per_hour = [0] * 24
    for row in hourly:
        if 0 <= row["h"] < 24:
            per_hour[row["h"]] = row["n"]
    samples = db.all_rows(
        "SELECT ts, cpu_pct, ram_used_mb, gpu_util_pct, vram_used_mb, queued_jobs, active_jobs, online_users "
        "FROM system_samples WHERE ts >= ? ORDER BY ts", (now - 6 * 3600,))
    step = max(1, len(samples) // 72)
    storage = storage_summary()
    profiles = cached_profiles()
    users_total = len(profiles)
    return_users = {
        "total": users_total,
        "verified": users_total,
        "admins": sum(1 for u in profiles if u.get("role") in ("admin", "owner")),
        "blocked": sum(1 for u in profiles if u.get("blocked")),
        "new_24h": sum(1 for u in profiles if float(u.get("created_at") or 0) >= day),
        "new_7d": sum(1 for u in profiles if float(u.get("created_at") or 0) >= week),
        "online_5m": latest.get("online_users", 0),
        "active_24h": sum(1 for u in profiles if float(u.get("last_seen_at") or 0) >= day),
        "peak_online_7d": db.scalar("SELECT MAX(online_users) FROM system_samples WHERE ts >= ?", (week,)),
    }
    return {
        "now": now,
        "system": latest,
        "gpu_name": _nvidia_smi().get("gpu_name"),
        "users": return_users,
        "tryons": {
            "total": db.scalar("SELECT COUNT(*) FROM tryon_jobs"),
            "day": jobs_day.get("n") or 0,
            "day_ok": jobs_day.get("ok") or 0,
            "day_failed": jobs_day.get("failed") or 0,
            "day_gpu_minutes": round((jobs_day.get("gpu") or 0) / 60, 1),
            "day_avg_wait_s": round(jobs_day.get("wait") or 0, 1),
            "week": db.scalar("SELECT COUNT(*) FROM tryon_jobs WHERE created_at >= ?", (week,)),
            "recolors_week": db.scalar("SELECT SUM(recolors) FROM tryon_jobs WHERE created_at >= ?", (week,)),
            "per_hour_24h": per_hour,
        },
        "traffic_24h": {
            "requests": traffic_day.get("requests") or 0,
            "in_mb": round((traffic_day.get("bin") or 0) / 2**20, 1),
            "out_mb": round((traffic_day.get("bout") or 0) / 2**20, 1),
            "avg_ms": round(traffic_day.get("ms") or 0, 1),
        },
        "storage_mb": storage,
        "storage_per_user_mb": round(storage["total"] / max(users_total, 1), 1),
        "capacity": capacity(avg_job, think, _gpus_online()) | {"measured_jobs": measured_jobs,
                                                                  "measured_gaps": measured_gaps},
        "workers": _workers(),
        "series": samples[::step],
        "settings": _public_config(),
        "firebase": store.status(),
    }


_profiles_cache: dict[str, Any] = {"at": 0.0, "items": None}


def cached_profiles(force: bool = False) -> list[dict[str, Any]]:
    """All user profiles from Firestore, re-read at most every 2 minutes: each read of
    the collection costs one Firestore read per user (free plan: 50 000 a day)."""
    if force or _profiles_cache["items"] is None or time.time() - _profiles_cache["at"] > 120:
        _profiles_cache.update(at=time.time(), items=store.get().list_users())
    return _profiles_cache["items"]


def profiles_changed() -> None:
    _profiles_cache["items"] = None


def _local_stats() -> dict[str, dict[str, Any]]:
    """Per-user numbers that live on the laptop (try-ons, GPU time, traffic)."""
    day = time.time() - 86400
    stats: dict[str, dict[str, Any]] = {}
    for r in db.all_rows(
        "SELECT user_id, COUNT(*) AS tryons, SUM(created_at >= ?) AS tryons_24h, SUM(status = 'failed') AS failed, "
        "COALESCE(SUM(gpu_seconds), 0) AS gpu, COALESCE(SUM(recolors), 0) AS recolors, "
        "COALESCE(SUM(bytes_in + bytes_out), 0) AS bytes FROM tryon_jobs WHERE user_id IS NOT NULL GROUP BY user_id",
        (day,)):
        stats[r["user_id"]] = {"tryons": r["tryons"], "tryons_24h": r["tryons_24h"] or 0, "tryons_failed": r["failed"] or 0,
                               "gpu_seconds": r["gpu"], "recolors": r["recolors"], "job_bytes": r["bytes"]}
    for r in db.all_rows("SELECT user_id, COUNT(*) AS n, COALESCE(SUM(bytes_in + bytes_out), 0) AS traffic "
                         "FROM usage_events WHERE user_id IS NOT NULL GROUP BY user_id"):
        stats.setdefault(r["user_id"], {}).update(requests=r["n"], traffic=r["traffic"])
    return stats


def _user_rows(query: str = "") -> list[dict[str, Any]]:
    flush_usage()
    stats = _local_stats()
    q = query.strip().lower()
    rows = []
    for p in cached_profiles():
        if q and q not in f"{p.get('email', '')} {p.get('name', '')}".lower():
            continue
        st = stats.get(p["uid"], {})
        rows.append({
            "id": p["uid"], "email": p.get("email", ""), "name": p.get("name", ""), "role": p.get("role", "user"),
            "verified": True, "blocked": bool(p.get("blocked")),
            "created_at": p.get("created_at"), "last_login_at": p.get("last_login_at"), "last_seen_at": p.get("last_seen_at"),
            "last_ip": p.get("last_ip", ""), "signup_ip": p.get("signup_ip", ""),
            "tryons": st.get("tryons", 0), "tryons_24h": st.get("tryons_24h", 0), "tryons_failed": st.get("tryons_failed", 0),
            "gpu_minutes": round(st.get("gpu_seconds", 0) / 60, 1), "recolors": st.get("recolors", 0),
            "storage_mb": round((st.get("job_bytes", 0) + float(p.get("catalog_bytes") or 0)) / 2**20, 1),
            "catalog_items": int(p.get("catalog_count") or 0), "looks": int(p.get("looks_count") or 0),
            "requests": st.get("requests", 0), "traffic_mb": round(st.get("traffic", 0) / 2**20, 1),
        })
    rows.sort(key=lambda r: float(r["created_at"] or 0), reverse=True)
    return rows


@router.get("/users")
def users(request: Request, q: str = ""):
    auth.require_role(request, "admin")
    return {"items": _user_rows(q)}


@router.get("/users.csv")
def users_csv(request: Request):
    auth.require_role(request, "admin")
    rows = sorted(_user_rows(), key=lambda r: float(r["created_at"] or 0))
    buf = io.StringIO()
    if rows:
        fmt = lambda v: time.strftime("%Y-%m-%d %H:%M", time.localtime(v)) if isinstance(v, float) and v > 1e9 else v  # noqa: E731
        writer = csv.DictWriter(buf, fieldnames=list(rows[0].keys()), delimiter=";")
        writer.writeheader()
        for r in rows:
            writer.writerow({k: fmt(v) for k, v in r.items()})
    return Response(content="\ufeff" + buf.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": 'attachment; filename="fitme_users.csv"'})


@router.get("/users/{user_id}")
def user_detail(user_id: str, request: Request):
    auth.require_role(request, "admin")
    rows = [r for r in _user_rows() if r["id"] == user_id]
    if not rows:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    jobs = db.all_rows(
        "SELECT job_id, created_at, finished_at, status, model, items, steps, gpu_seconds, recolors, error "
        "FROM tryon_jobs WHERE user_id = ? ORDER BY created_at DESC LIMIT 50", (user_id,))
    endpoints = db.all_rows(
        "SELECT path, COUNT(*) AS n, ROUND(AVG(ms), 1) AS avg_ms, SUM(bytes_out) AS bytes_out "
        "FROM usage_events WHERE user_id = ? GROUP BY path ORDER BY n DESC LIMIT 20", (user_id,))
    return {"user": rows[0], "jobs": jobs, "endpoints": endpoints}


class RolePayload(BaseModel):
    role: str


class BlockPayload(BaseModel):
    blocked: bool


def _target(user_id: str) -> dict[str, Any]:
    row = store.get().get_user(user_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    return row


@router.post("/users/{user_id}/role")
def set_role(user_id: str, payload: RolePayload, request: Request):
    actor = auth.require_role(request, "owner")
    target = _target(user_id)
    if payload.role not in ("admin", "user"):
        raise HTTPException(status_code=422, detail="Роль может быть только admin или user")
    if user_id == actor["id"] or target.get("role") == "owner":
        raise HTTPException(status_code=400, detail="Роль создателя не меняется")
    store.get().update_user(user_id, {"role": payload.role})
    profiles_changed()
    auth.forget(user_id)
    return {"status": "ok", "role": payload.role}


@router.post("/users/{user_id}/block")
def set_blocked(user_id: str, payload: BlockPayload, request: Request):
    actor = auth.require_role(request, "admin")
    target = _target(user_id)
    if target.get("role") == "owner" or user_id == actor["id"]:
        raise HTTPException(status_code=400, detail="Этот аккаунт нельзя заблокировать")
    if target.get("role") == "admin" and actor["role"] != "owner":
        raise HTTPException(status_code=403, detail="Администратора может заблокировать только создатель")
    st = store.get()
    st.update_user(user_id, {"blocked": bool(payload.blocked)})
    st.set_auth_disabled(user_id, bool(payload.blocked))  # Firebase refuses sign-in too
    profiles_changed()
    auth.forget(user_id)
    return {"status": "ok", "blocked": payload.blocked}


@router.delete("/users/{user_id}")
def delete_user(user_id: str, request: Request):
    auth.require_role(request, "owner")
    target = _target(user_id)
    if target.get("role") == "owner":
        raise HTTPException(status_code=400, detail="Аккаунт создателя удалить нельзя")
    auth.delete_user_everywhere(user_id)
    profiles_changed()
    return {"status": "deleted"}


@router.get("/jobs")
def recent_jobs(request: Request, limit: int = 100):
    auth.require_role(request, "admin")
    emails = {u["uid"]: u.get("email", "") for u in cached_profiles()}
    items = db.all_rows(
        "SELECT job_id, created_at, started_at, finished_at, status, model, items, steps, gpu_seconds, recolors, "
        "error, user_id FROM tryon_jobs ORDER BY created_at DESC LIMIT ?", (max(1, min(limit, 500)),))
    for it in items:
        it["email"] = emails.get(it.pop("user_id") or "", "")
    return {"items": items}


class SettingsPayload(BaseModel):
    registration_open: bool | None = None
    daily_tryon_limit: int | None = None


def _public_config() -> dict[str, Any]:
    cfg = store.get().get_config()
    return {"registration_open": bool(cfg.get("registration_open", True)),
            "daily_tryon_limit": int(cfg.get("daily_tryon_limit") or 0)}


@router.get("/settings")
def get_settings(request: Request):
    auth.require_role(request, "admin")
    return {"settings": _public_config(), "firebase": store.status(),
            "owner_email_configured": bool(auth.owner_email())}


@router.post("/settings")
def update_settings(payload: SettingsPayload, request: Request):
    auth.require_role(request, "owner")
    fields: dict[str, Any] = {}
    if payload.registration_open is not None:
        fields["registration_open"] = bool(payload.registration_open)
    if payload.daily_tryon_limit is not None:
        fields["daily_tryon_limit"] = max(0, min(int(payload.daily_tryon_limit), 1000))
    if fields:
        store.get().update_config(fields)
    return {"settings": _public_config()}
