"""Minimal Hugging Face Space (Gradio) client used for the free cloud try-on mode.

Talks to the Gradio HTTP queue API directly, so it works with Gradio 4.x-6.x
servers without depending on a particular gradio_client version.
"""
from __future__ import annotations

import io
import json
import uuid
from pathlib import Path
from typing import Any

import httpx
from PIL import Image, ImageOps


class QuotaExceeded(RuntimeError):
    """ZeroGPU daily quota is used up for this token/IP."""


class HFSpace:
    def __init__(self, space_id: str, token: str | None = None, timeout: float = 600.0):
        self.space_id = space_id
        headers = {"User-Agent": "FitMe-backend/1.0"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self.http = httpx.Client(
            headers=headers,
            timeout=httpx.Timeout(30.0, read=timeout),
            follow_redirects=True,
        )
        self.host = (
            "https://"
            + space_id.lower().replace("/", "-").replace(".", "-").replace("_", "-")
            + ".hf.space"
        )
        self.prefix = ""
        self.fn_index: dict[str, int] = {}

    def close(self) -> None:
        self.http.close()

    def status(self) -> tuple[bool, str | None]:
        try:
            info = self.http.get(f"https://huggingface.co/api/spaces/{self.space_id}", timeout=10.0).json()
        except Exception as exc:  # network problems
            return False, f"{type(exc).__name__}: {exc}"
        stage = (info.get("runtime") or {}).get("stage")
        if info.get("host"):
            self.host = str(info["host"]).rstrip("/")
        if stage == "RUNNING":
            return True, None
        return False, f"Space {self.space_id}: {stage or info.get('error') or 'unknown'}"

    def connect(self) -> None:
        self.status()
        cfg = self.http.get(self.host + "/config").raise_for_status().json()
        prefix = cfg.get("api_prefix") or ""
        self.prefix = "" if prefix == "/" else prefix
        self.fn_index = {
            d.get("api_name"): i
            for i, d in enumerate(cfg.get("dependencies", []))
            if d.get("api_name")
        }

    def upload(self, path: Path, max_side: int = 1536) -> dict[str, Any]:
        if not self.fn_index:
            self.connect()
        image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        image.thumbnail((max_side, max_side))
        buf = io.BytesIO()
        image.save(buf, format="JPEG", quality=95)
        r = self.http.post(
            self.host + self.prefix + "/upload",
            files={"files": (path.stem + ".jpg", buf.getvalue(), "image/jpeg")},
        )
        r.raise_for_status()
        return {"path": r.json()[0], "meta": {"_type": "gradio.FileData"}}

    def call(self, api_name: str, data: list[Any]) -> list[Any]:
        if not self.fn_index:
            self.connect()
        api = api_name.lstrip("/")
        if api not in self.fn_index:
            raise RuntimeError(f"{self.space_id}: endpoint /{api} not found")
        session = uuid.uuid4().hex[:11]
        self.http.post(
            self.host + self.prefix + "/queue/join",
            json={
                "data": data,
                "fn_index": self.fn_index[api],
                "session_hash": session,
                "event_data": None,
                "trigger_id": None,
            },
        ).raise_for_status()
        with self.http.stream(
            "GET",
            self.host + self.prefix + "/queue/data",
            params={"session_hash": session},
        ) as stream:
            for line in stream.iter_lines():
                if not line.startswith("data:"):
                    continue
                msg = json.loads(line[5:].strip())
                if msg.get("msg") != "process_completed":
                    continue
                out = msg.get("output") or {}
                if msg.get("success"):
                    return out.get("data") or []
                err = str(out.get("error") or msg.get("title") or "unknown error")
                if "quota" in err.lower():
                    raise QuotaExceeded(err)
                raise RuntimeError(err)
        raise RuntimeError("Space closed the stream without a result")

    def download_image(self, file_data: Any) -> bytes:
        while isinstance(file_data, list):
            file_data = file_data[0]
        if isinstance(file_data, dict) and "image" in file_data:
            file_data = file_data["image"]
        url = file_data.get("url") if isinstance(file_data, dict) else None
        if not url:
            url = self.host + self.prefix + "/file=" + file_data["path"]
        r = self.http.get(url)
        r.raise_for_status()
        out = io.BytesIO()
        Image.open(io.BytesIO(r.content)).convert("RGB").save(out, format="PNG")
        return out.getvalue()


def fashn_try_on(
    space_id: str,
    token: str | None,
    person_path: Path,
    garment_path: Path,
    fashn_category: str,
    steps: int = 30,
    garment_photo_type: str = "flat-lay",
    seed: int = 42,
) -> bytes:
    space = HFSpace(space_id, token)
    try:
        space.connect()
        data = space.call(
            "try_on",
            [
                space.upload(person_path),
                space.upload(garment_path),
                fashn_category,
                garment_photo_type,
                steps,
                1.5,
                seed,
                True,
            ],
        )
        return space.download_image(data[0])
    finally:
        space.close()


# --------------------------------------------------------------------------- #
# Other free try-on models that run on Hugging Face ZeroGPU Spaces.
# The Space APIs are the ones used by benchmark/bench_spaces.py.
# --------------------------------------------------------------------------- #
def _strip(fd: Any) -> Any:
    if isinstance(fd, dict) and "path" in fd:
        return {"path": fd["path"], "meta": {"_type": "gradio.FileData"}}
    return fd


def _run_fashn(s: HFSpace, person: Path, garment: Path, category: str, steps: int, seed: int, photo_type: str):
    cat = {"upper_body": "tops", "lower_body": "bottoms", "dresses": "one-pieces"}[category]
    return s.call("try_on", [s.upload(person), s.upload(garment), cat,
                             "model" if photo_type == "model" else "flat-lay", steps, 1.5, seed, True])[0]


def _run_leffa(s: HFSpace, person: Path, garment: Path, category: str, steps: int, seed: int, photo_type: str):
    model_type = "viton_hd" if category == "upper_body" else "dress_code"
    return s.call("leffa_predict_vt", [s.upload(person), s.upload(garment), False, steps, 2.5, seed,
                                       model_type, category, False])[0]


def _run_fitdit(s: HFSpace, person: Path, garment: Path, category: str, steps: int, seed: int, photo_type: str):
    cat = {"upper_body": "Upper-body", "lower_body": "Lower-body", "dresses": "Dresses"}[category]
    p = s.upload(person)
    mask = s.call("generate_mask", [p, cat, 0, 0, 0, 0])
    editor = mask[0]
    pre_mask = {
        "background": _strip(editor.get("background")),
        "layers": [_strip(x) for x in editor.get("layers") or []],
        "composite": _strip(editor.get("composite")),
        "id": None,
    }
    return s.call("process", [p, s.upload(garment), pre_mask, _strip(mask[1]), min(steps, 30), 2, seed, 1,
                              "768x1024"])[0]


def _run_idm(s: HFSpace, person: Path, garment: Path, category: str, steps: int, seed: int, photo_type: str):
    p = s.upload(person)
    return s.call("tryon", [{"background": p, "layers": [], "composite": None}, s.upload(garment),
                            "garment", True, True, min(steps, 40), seed])[0]


def _run_ootd(s: HFSpace, person: Path, garment: Path, category: str, steps: int, seed: int, photo_type: str):
    if category == "upper_body":
        return s.call("process_hd", [s.upload(person), s.upload(garment), 1, min(steps, 40), 2, seed])[0]
    cat = {"lower_body": "Lower-body", "dresses": "Dress"}[category]
    return s.call("process_dc", [s.upload(person), s.upload(garment), cat, 1, min(steps, 40), 2, seed])[0]


ALL_CATEGORIES = ("upper_body", "lower_body", "dresses")

# id -> (Space, adapter, supported categories)
SPACE_MODELS: dict[str, tuple[str, Any, tuple[str, ...]]] = {
    "fashn_cloud": ("fashn-ai/fashn-vton-1.5", _run_fashn, ALL_CATEGORIES),
    "leffa": ("franciszzj/Leffa", _run_leffa, ALL_CATEGORIES),
    "fitdit": ("BoyuanJiang/FitDiT", _run_fitdit, ALL_CATEGORIES),
    "idm": ("yisol/IDM-VTON", _run_idm, ("upper_body",)),
    "ootd": ("levihsu/OOTDiffusion", _run_ootd, ALL_CATEGORIES),
}


def space_try_on(
    model_id: str,
    token: str | None,
    person_path: Path,
    garment_path: Path,
    category: str,
    steps: int = 30,
    seed: int = 42,
    photo_type: str = "auto",
) -> bytes:
    space_id, adapter, categories = SPACE_MODELS[model_id]
    if category not in categories:
        raise RuntimeError(f"{model_id} не поддерживает категорию {category}")
    space = HFSpace(space_id, token)
    try:
        space.connect()
        return space.download_image(adapter(space, person_path, garment_path, category, steps, seed, photo_type))
    finally:
        space.close()
