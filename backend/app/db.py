"""SQLite storage on the laptop for FitMe: try-on jobs, the request log and machine load.

One file (backend/data/fitme.db). Every call opens its own short connection, so it is safe
from FastAPI worker threads and from the background job threads. WAL mode lets the admin
panel read while a job is being written.
"""
from __future__ import annotations

import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

SCHEMA_VERSION = 2

SCHEMA = """
-- Accounts, catalog, looks and settings live in Firebase (see store.py). This file keeps
-- the high-volume data that never leaves the laptop: try-on jobs, request log, machine load.
CREATE TABLE IF NOT EXISTS tryon_jobs (
    job_id        TEXT PRIMARY KEY,
    user_id       TEXT,                    -- Firebase uid
    created_at    REAL NOT NULL,
    started_at    REAL,
    finished_at   REAL,
    status        TEXT NOT NULL,
    model         TEXT NOT NULL DEFAULT '',
    provider      TEXT NOT NULL DEFAULT '',
    items         INTEGER NOT NULL DEFAULT 1,
    steps         INTEGER NOT NULL DEFAULT 0,
    gpu_seconds   REAL NOT NULL DEFAULT 0,  -- time the GPU itself worked on this job
    bytes_in      INTEGER NOT NULL DEFAULT 0,
    bytes_out     INTEGER NOT NULL DEFAULT 0,
    recolors      INTEGER NOT NULL DEFAULT 0,
    error         TEXT,
    data          TEXT NOT NULL            -- full job state as JSON (for the app after a restart)
);
CREATE INDEX IF NOT EXISTS jobs_user ON tryon_jobs(user_id, created_at);
CREATE INDEX IF NOT EXISTS jobs_created ON tryon_jobs(created_at);

-- every API / picture request (method, normalised path, status, time, traffic)
CREATE TABLE IF NOT EXISTS usage_events (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts        REAL NOT NULL,
    user_id   TEXT,
    method    TEXT NOT NULL,
    path      TEXT NOT NULL,
    status    INTEGER NOT NULL,
    ms        REAL NOT NULL,
    bytes_in  INTEGER NOT NULL DEFAULT 0,
    bytes_out INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS usage_ts ON usage_events(ts);
CREATE INDEX IF NOT EXISTS usage_user ON usage_events(user_id, ts);

-- machine load every 30 s (CPU, RAM, GPU, queue)
CREATE TABLE IF NOT EXISTS system_samples (
    ts            REAL PRIMARY KEY,
    cpu_pct       REAL,
    ram_used_mb   REAL,
    ram_total_mb  REAL,
    proc_rss_mb   REAL,
    disk_free_gb  REAL,
    gpu_util_pct  REAL,
    vram_used_mb  REAL,
    vram_total_mb REAL,
    gpu_temp_c    REAL,
    gpu_power_w   REAL,
    active_jobs   INTEGER,
    queued_jobs   INTEGER,
    online_users  INTEGER
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

_path: Path | None = None
_init_lock = threading.Lock()


def init(path: Path) -> None:
    global _path
    with _init_lock:
        _path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        with connect() as con:
            con.executescript(SCHEMA)
            con.execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    if _path is None:
        raise RuntimeError("database is not initialised")
    con = sqlite3.connect(_path, timeout=15, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    con.execute("PRAGMA journal_mode = WAL")
    con.execute("PRAGMA synchronous = NORMAL")
    try:
        yield con
    finally:
        con.close()


@contextmanager
def transaction() -> Iterator[sqlite3.Connection]:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        try:
            yield con
            con.execute("COMMIT")
        except BaseException:
            con.execute("ROLLBACK")
            raise


def one(sql: str, args: tuple = ()) -> dict[str, Any] | None:
    with connect() as con:
        row = con.execute(sql, args).fetchone()
        return dict(row) if row else None


def all_rows(sql: str, args: tuple = ()) -> list[dict[str, Any]]:
    with connect() as con:
        return [dict(r) for r in con.execute(sql, args).fetchall()]


def execute(sql: str, args: tuple = ()) -> int:
    """Runs one statement; returns lastrowid (INSERT) or rowcount (UPDATE/DELETE)."""
    with connect() as con:
        cur = con.execute(sql, args)
        return cur.lastrowid if sql.lstrip().upper().startswith("INSERT") else cur.rowcount


def scalar(sql: str, args: tuple = (), default: Any = 0) -> Any:
    with connect() as con:
        row = con.execute(sql, args).fetchone()
        return default if row is None or row[0] is None else row[0]


def now() -> float:
    return time.time()
