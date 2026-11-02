"""Accounts on Firebase: the app signs in with Firebase Authentication and sends its
ID token; the backend checks it and keeps the profile and role in Firestore.

Roles
  owner  - the creator of FitMe: everything (roles, deleting accounts, settings)
  admin  - user table, usage analytics, blocking clients
  user   - a client: only their own catalog, try-ons and looks

Passwords never reach the backend: Firebase stores and checks them. Sign-up confirmation
and password-reset e-mails are sent by Firebase too.
"""
from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from . import store

ROLES = ("owner", "admin", "user")
ROLE_RANK = {"user": 0, "admin": 1, "owner": 2}
TOKEN_CACHE_S = 300
USER_CACHE_S = 30

_data_dir: Path = Path(".")
_token_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_user_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_cache_lock = threading.Lock()
_create_lock = threading.Lock()

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])


def configure(data_dir: Path) -> None:
    global _data_dir
    _data_dir = data_dir


def forget(uid: str | None = None) -> None:
    """Drop cached profiles (after a role change, a block, a deletion)."""
    with _cache_lock:
        if uid is None:
            _user_cache.clear()
            _token_cache.clear()
        else:
            _user_cache.pop(uid, None)
            for token in [t for t, (_, claims) in _token_cache.items() if claims.get("uid") == uid]:
                _token_cache.pop(token, None)


# ------------------------------------------------------------------ owner & web config
def owner_email() -> str:
    value = os.getenv("FITME_OWNER_EMAIL", "").strip().lower()
    path = _data_dir / "owner_email.txt"
    if not value and path.exists():
        value = path.read_text(encoding="utf-8", errors="ignore").strip().lower()
    return value


def web_config() -> dict[str, str]:
    """Public Firebase web keys (apiKey is not a secret) for the web admin page."""
    path = _data_dir / "firebase_web.json"
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return {"apiKey": str(data.get("apiKey", "")), "projectId": str(data.get("projectId", ""))}
        except ValueError:
            pass
    return {"apiKey": os.getenv("FITME_FIREBASE_API_KEY", ""), "projectId": store.status()["project_id"]}


# ------------------------------------------------------------------ requests
def client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip()[:64]
    return (request.client.host if request.client else "")[:64]


def token_from(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip() or None
    return request.query_params.get("token") or None


def claims_for(token: str) -> dict[str, Any] | None:
    now = time.time()
    with _cache_lock:
        hit = _token_cache.get(token)
        if hit and hit[0] > now:
            return hit[1]
    try:
        claims = store.get().verify_token(token)
    except store.TokenError:
        return None
    except HTTPException:  # Firebase not configured
        return None
    expires = min(now + TOKEN_CACHE_S, float(claims.get("exp") or now + TOKEN_CACHE_S))
    with _cache_lock:
        if len(_token_cache) > 5000:
            _token_cache.clear()
        _token_cache[token] = (expires, claims)
    return claims


def _profile(uid: str) -> dict[str, Any] | None:
    now = time.time()
    with _cache_lock:
        hit = _user_cache.get(uid)
        if hit and hit[0] > now:
            return hit[1]
    profile = store.get().get_user(uid)
    if profile is not None:
        with _cache_lock:
            _user_cache[uid] = (now + USER_CACHE_S, profile)
    return profile


def resolve_user(request: Request) -> dict[str, Any] | None:
    """Profile of the request's Firebase token, or None. Updates 'last seen' at most once a minute."""
    token = token_from(request)
    if not token or not store.available():
        return None
    claims = claims_for(token)
    if claims is None or not claims.get("email_verified"):
        return None
    uid = str(claims["uid"])
    profile = _profile(uid)
    if profile is None or profile.get("blocked"):
        return None
    if time.time() - float(profile.get("last_seen_at") or 0) > 60:
        fields = {"last_seen_at": time.time(), "last_ip": client_ip(request)}
        try:
            store.get().update_user(uid, fields)
        except Exception as exc:  # never fail a request because of 'last seen'
            print(f"[FitMe] last-seen update failed: {exc}")
        profile = profile | fields
        with _cache_lock:
            _user_cache[uid] = (time.time() + USER_CACHE_S, profile)
    return profile | {"id": uid}


def require_user(request: Request) -> dict[str, Any]:
    user = getattr(request.state, "user", None)
    if user is None:
        store.get()  # 503 with the setup hint when Firebase is not configured
        raise HTTPException(status_code=401, detail="Войдите в аккаунт")
    return user


def require_role(request: Request, role: str) -> dict[str, Any]:
    user = require_user(request)
    if ROLE_RANK[user.get("role", "user")] < ROLE_RANK[role]:
        raise HTTPException(status_code=403, detail="Недостаточно прав")
    return user


def public_user(profile: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": profile.get("id") or profile.get("uid"),
        "email": profile.get("email", ""),
        "name": profile.get("name", ""),
        "role": profile.get("role", "user"),
        "verified": True,
        "created_at": profile.get("created_at"),
    }


# Set by main.py: moves catalog/looks made before accounts existed to the creator.
_legacy_claimer = None
_file_cleaner = None


def set_legacy_claimer(fn) -> None:
    global _legacy_claimer
    _legacy_claimer = fn


def set_file_cleaner(fn) -> None:
    global _file_cleaner
    _file_cleaner = fn


def _create_profile(claims: dict[str, Any], request: Request) -> dict[str, Any]:
    """First visit of a confirmed Firebase account: make its FitMe profile."""
    st = store.get()
    uid, email = str(claims["uid"]), str(claims.get("email") or "").lower()
    with _create_lock:
        existing = st.get_user(uid)
        if existing is not None:
            return existing
        config = st.get_config()
        configured_owner = owner_email()
        if configured_owner:
            role = "owner" if email == configured_owner else "user"
        else:
            role = "user" if config.get("owner_uid") else "owner"  # the first account is the creator
        if role != "owner" and not config.get("registration_open", True):
            raise HTTPException(status_code=403, detail="Регистрация временно закрыта")
        now = time.time()
        profile = {
            "email": email, "name": "", "role": role, "blocked": False,
            "created_at": now, "last_seen_at": now, "last_login_at": now,
            "last_ip": client_ip(request), "signup_ip": client_ip(request),
            "tryons": 0, "gpu_seconds": 0.0, "recolors": 0,
            "catalog_count": 0, "catalog_bytes": 0, "looks_count": 0,
        }
        st.create_user(uid, profile)
        if role == "owner":
            st.update_config({"owner_uid": uid})
            if _legacy_claimer is not None:
                try:
                    _legacy_claimer(uid)
                except Exception as exc:
                    print(f"[FitMe] moving old catalog/looks failed: {exc}")
        forget(uid)
        from . import admin  # the admin user list is cached

        admin.profiles_changed()
        return {"uid": uid} | profile


# ------------------------------------------------------------------ endpoints
class ProfilePayload(BaseModel):
    name: str


@router.get("/config")
def config():
    """Firebase keys for sign-in pages (public)."""
    return {"firebase": web_config(), "store": store.status()}


@router.post("/session")
def session(request: Request):
    """Called by the app right after a Firebase sign-in: creates the FitMe profile on the
    first visit and returns the account with its role."""
    token = token_from(request)
    if not token:
        raise HTTPException(status_code=401, detail="Войдите в аккаунт")
    st = store.get()
    claims = claims_for(token)
    if claims is None:
        raise HTTPException(status_code=401, detail="Сессия закончилась — войдите снова")
    if not claims.get("email_verified"):
        raise HTTPException(status_code=403, detail={"code": "not_verified",
                                                     "message": "Подтвердите почту: откройте ссылку из письма"})
    profile = st.get_user(str(claims["uid"])) or _create_profile(claims, request)
    if profile.get("blocked"):
        raise HTTPException(status_code=403, detail="Аккаунт заблокирован администратором")
    st.update_user(str(claims["uid"]), {"last_login_at": time.time(), "last_seen_at": time.time(),
                                        "last_ip": client_ip(request)})
    forget(str(claims["uid"]))
    return {"user": public_user(profile | {"id": str(claims["uid"])})}


@router.get("/me")
def me(request: Request):
    user = require_user(request)
    from . import db

    used_today = db.scalar("SELECT COUNT(*) FROM tryon_jobs WHERE user_id = ? AND created_at >= ?",
                           (user["id"], time.time() - 86400))
    limit = int(store.get().get_config().get("daily_tryon_limit") or 0) if user["role"] == "user" else 0
    return {
        "user": public_user(user),
        "usage": {
            "tryons_total": db.scalar("SELECT COUNT(*) FROM tryon_jobs WHERE user_id = ?", (user["id"],)),
            "tryons_24h": used_today,
            "daily_limit": limit,
            "looks": int(user.get("looks_count") or 0),
            "catalog": int(user.get("catalog_count") or 0),
        },
    }


@router.patch("/me")
def update_me(payload: ProfilePayload, request: Request):
    user = require_user(request)
    store.get().update_user(user["id"], {"name": payload.name.strip()[:60]})
    forget(user["id"])
    return {"user": public_user(user | {"name": payload.name.strip()[:60]})}


@router.post("/delete-account")
def delete_account(request: Request):
    """Google Play requires that users can delete their account from the app.
    The app re-enters the password with Firebase right before calling this."""
    user = require_user(request)
    if user["role"] == "owner":
        raise HTTPException(status_code=400, detail="Аккаунт создателя удалить нельзя")
    delete_user_everywhere(user["id"])
    return {"status": "deleted"}


def delete_user_everywhere(uid: str) -> None:
    st = store.get()
    if _file_cleaner is not None:
        try:
            _file_cleaner(uid)
        except Exception as exc:  # the account must go even if a file is locked
            print(f"[FitMe] file cleanup for {uid} failed: {exc}")
    st.delete_user_data(uid)
    st.delete_auth_user(uid)
    forget(uid)
    from . import admin

    admin.profiles_changed()
