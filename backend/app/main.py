from __future__ import annotations

import io
import json
import mimetypes
import os
import re
import time
from html import unescape
from urllib.parse import urljoin, urlparse
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageChops, ImageEnhance, ImageFilter, ImageOps
from typing import Any

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import Response
from pydantic import BaseModel

BASE_DIR = Path(
    os.getenv("FITME_STORAGE_DIR") or Path(__file__).resolve().parent.parent
)
UPLOAD_DIR = BASE_DIR / "uploads"
GENERATED_DIR = BASE_DIR / "generated"
CATALOG_DIR = BASE_DIR / "catalog"
DATA_DIR = BASE_DIR / "data"
LOOKS_FILE = DATA_DIR / "looks.json"
CATALOG_FILE = DATA_DIR / "catalog.json"
REMOTE_URL_FILE = DATA_DIR / "remote_ai_url.txt"

for path in (UPLOAD_DIR, GENERATED_DIR, CATALOG_DIR, DATA_DIR):
    path.mkdir(parents=True, exist_ok=True)

ENGINE = "FASHN VTON 1.5"
APP_VERSION = "3.0.0"
# Provider: "auto" (Kaggle if its URL is set and online, otherwise Hugging Face Space),
# "kaggle" (only Kaggle), "hf_space" (only Hugging Face Space).
PROVIDER_MODE = os.getenv("FITME_AI_PROVIDER", "auto").strip().lower()
FASHN_STEPS = max(10, min(int(os.getenv("FITME_FASHN_STEPS", "10")), 50))
HF_SPACE_ID = os.getenv("FITME_HF_SPACE", "fashn-ai/fashn-vton-1.5").strip()
HF_TOKEN_FILE = DATA_DIR / "hf_token.txt"
HF_STEPS = max(10, min(int(os.getenv("FITME_HF_STEPS", "30")), 50))
VALID_CATEGORIES = {"upper_body", "lower_body", "dresses"}
# Stretching the person photo to the body sliders distorts the face and background,
# so it is off unless explicitly enabled.
BODY_WARP = os.getenv("FITME_BODY_WARP", "0").strip().lower() in {"1", "true", "yes"}


def hf_token() -> str | None:
    """Free Hugging Face token (more ZeroGPU minutes): env HF_TOKEN or backend/data/hf_token.txt."""
    value = (os.getenv("HF_TOKEN") or "").strip()
    if not value and HF_TOKEN_FILE.exists():
        value = HF_TOKEN_FILE.read_text(encoding="utf-8", errors="ignore").strip()
    return value or None


# Try-on models the app can choose from. "fashn" runs on your own GPU (or Kaggle);
# the others run on free Hugging Face ZeroGPU Spaces (a few minutes of GPU per day).
MODEL_CATALOG: list[dict[str, Any]] = [
    {"id": "fashn", "title": "FASHN VTON 1.5", "where": "Ноутбук (ваша видеокарта)",
     "categories": ["upper_body", "lower_body", "dresses"], "license": "Apache-2.0",
     "limit": "без лимита", "note": "Основная модель: лучшая детализация + улучшение качества"},
    {"id": "fashn_cloud", "title": "FASHN VTON 1.5 (облако)", "where": "Hugging Face ZeroGPU",
     "categories": ["upper_body", "lower_body", "dresses"], "license": "Apache-2.0",
     "limit": "≈5 мин GPU в день", "note": "Когда ноутбук выключен"},
    {"id": "leffa", "title": "Leffa", "where": "Hugging Face ZeroGPU",
     "categories": ["upper_body", "lower_body", "dresses"], "license": "MIT (+ условия датасетов)",
     "limit": "≈5 мин GPU в день", "note": "Хорошо держит рисунок и надписи"},
    {"id": "fitdit", "title": "FitDiT", "where": "Hugging Face ZeroGPU",
     "categories": ["upper_body", "lower_body", "dresses"], "license": "CC BY-NC-SA 4.0",
     "limit": "≈5 мин GPU в день", "note": "Сильная текстура ткани, только некоммерческое"},
    {"id": "idm", "title": "IDM-VTON", "where": "Hugging Face ZeroGPU",
     "categories": ["upper_body"], "license": "CC BY-NC-SA 4.0",
     "limit": "≈5 мин GPU в день", "note": "Только верх, только некоммерческое"},
    {"id": "ootd", "title": "OOTDiffusion", "where": "Hugging Face ZeroGPU",
     "categories": ["upper_body", "lower_body", "dresses"], "license": "CC BY-NC-SA 4.0",
     "limit": "≈5 мин GPU в день", "note": "Старее, для сравнения"},
]
MODEL_IDS = {m["id"] for m in MODEL_CATALOG}


def model_info(model_id: str) -> dict[str, Any]:
    return next((m for m in MODEL_CATALOG if m["id"] == model_id), MODEL_CATALOG[0])

app = FastAPI(
    title="FitMe AI CLEAN MVP",
    version=APP_VERSION,
    description="FitMe MVP: Flutter -> FastAPI -> FASHN VTON 1.5 on Kaggle GPU",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

API_KEY = (os.getenv("FITME_API_KEY") or "").strip()
OPEN_PATHS = {"/", "/health", "/docs", "/openapi.json"}


@app.middleware("http")
async def require_api_key(request, call_next):
    """When FITME_API_KEY is set (internet/tunnel mode) every request except /health needs it."""
    if API_KEY and request.method != "OPTIONS" and request.url.path not in OPEN_PATHS:
        supplied = request.headers.get("x-fitme-key") or request.query_params.get("key") or ""
        if supplied != API_KEY:
            return Response(content='{"detail":"Invalid or missing FitMe key"}', status_code=401, media_type="application/json")
    return await call_next(request)


app.mount("/uploads", StaticFiles(directory=str(UPLOAD_DIR)), name="uploads")
app.mount("/generated", StaticFiles(directory=str(GENERATED_DIR)), name="generated")
app.mount("/catalog", StaticFiles(directory=str(CATALOG_DIR)), name="catalog")

JOBS: dict[str, dict[str, Any]] = {}

_REMBG_SESSION = None
_REMBG_LOCK = threading.Lock()


def _get_human_cutout_session():
    global _REMBG_SESSION
    if _REMBG_SESSION is not None:
        return _REMBG_SESSION

    with _REMBG_LOCK:
        if _REMBG_SESSION is None:
            try:
                from rembg import new_session
            except Exception as exc:
                raise RuntimeError(
                    "rembg is not installed. Run the Python 3.14 cutout fix first"
                ) from exc
            _REMBG_SESSION = new_session("u2net_human_seg")
    return _REMBG_SESSION


def _trim_transparent_person(png_bytes: bytes) -> bytes:
    image = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        return png_bytes

    left, top, right, bottom = bbox
    person_w = max(1, right - left)
    person_h = max(1, bottom - top)
    margin_x = max(12, int(person_w * 0.05))
    margin_y = max(12, int(person_h * 0.035))
    crop_box = (
        max(0, left - margin_x),
        max(0, top - margin_y),
        min(image.width, right + margin_x),
        min(image.height, bottom + margin_y),
    )
    image = image.crop(crop_box)

    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


class SaveLookPayload(BaseModel):
    job_id: str
    title: str | None = None
    gender: str | None = None
    size: str | None = None
    fit: str | None = None
    color: str | None = None


class ImportUrlPayload(BaseModel):
    source_url: str
    category: str = "upper_body"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_remote_url(raw: str) -> str:
    value = (raw or "").strip()
    if not value:
        return ""

    match = re.search(r"https?://[^\s\"']+", value, flags=re.IGNORECASE)
    if match:
        value = match.group(0)
    else:
        value = value.strip().strip("\"'")
        if value.lower().startswith("set "):
            value = value[4:].strip().strip("\"'")
        if "=" in value:
            left, right = value.split("=", 1)
            if "url" in left.lower():
                value = right.strip().strip("\"'")
        value = value.strip().rstrip("/")
        if value and not value.lower().startswith(("http://", "https://")):
            value = "https://" + value

    return value.strip().strip("\"'").rstrip("/")


def get_remote_url() -> str:
    env_value = normalize_remote_url(os.getenv("FITME_REMOTE_AI_URL", ""))
    if env_value:
        return env_value

    if REMOTE_URL_FILE.exists():
        return normalize_remote_url(
            REMOTE_URL_FILE.read_text(encoding="utf-8", errors="ignore")
        )

    return ""


def load_json_list(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except Exception:
        return []


def save_json_list(path: Path, items: list[dict[str, Any]]) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(items, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    tmp.replace(path)


def safe_filename(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", name or "image.jpg")
    return cleaned[:120] or "image.jpg"


def suffix_for(upload: UploadFile) -> str:
    suffix = Path(safe_filename(upload.filename or "image.jpg")).suffix.lower()
    return suffix if suffix in {".jpg", ".jpeg", ".png", ".webp"} else ".jpg"


def image_mime(path: Path) -> str:
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "image/jpeg"


def fashn_category(category: str) -> str:
    return {
        "upper_body": "tops",
        "lower_body": "bottoms",
        "dresses": "one-pieces",
    }.get(category, "tops")


def remote_health(timeout: float = 8.0) -> tuple[bool, dict[str, Any], str | None]:
    url = get_remote_url()
    if not url:
        return False, {}, "Remote URL is not configured"

    try:
        response = httpx.get(
            f"{url}/health",
            timeout=timeout,
            follow_redirects=True,
        )
        if response.status_code != 200:
            return False, {}, f"Remote HTTP {response.status_code}"
        try:
            details = response.json()
        except Exception:
            details = {"text": response.text[:500]}
        return True, details, None
    except Exception as exc:
        return False, {}, f"{type(exc).__name__}: {exc}"


def hf_space_health() -> tuple[bool, dict[str, Any], str | None]:
    from .hf_space import HFSpace

    space = HFSpace(HF_SPACE_ID, hf_token())
    try:
        ok, error = space.status()
    finally:
        space.close()
    return ok, {"space": HF_SPACE_ID, "token": bool(hf_token()), "steps": HF_STEPS}, error


def resolve_provider(timeout: float = 8.0) -> tuple[str, bool, dict[str, Any], str | None]:
    """Returns (provider, online, details, error)."""
    if PROVIDER_MODE in {"kaggle", "remote_fashn"}:
        online, details, error = remote_health(timeout)
        return "remote_fashn", online, details, error
    if PROVIDER_MODE == "hf_space":
        online, details, error = hf_space_health()
        return "hf_space", online, details, error

    kaggle_error = None
    if get_remote_url():
        online, details, kaggle_error = remote_health(timeout)
        if online:
            return "remote_fashn", True, details, None
    online, details, error = hf_space_health()
    if kaggle_error:
        details = {**details, "kaggle_error": kaggle_error}
    return "hf_space", online, details, error


def browser_headers() -> dict[str, str]:
    return {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/126.0 Safari/537.36"
        ),
        "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    }


def _first_meta(content: str, patterns: list[str]) -> str | None:
    for pattern in patterns:
        match = re.search(pattern, content, flags=re.IGNORECASE | re.DOTALL)
        if match:
            value = unescape(match.group(1)).strip()
            if value:
                return value
    return None


def discover_product_image(source_url: str) -> tuple[str, str, str]:
    url = source_url.strip()
    if not url.startswith(("http://", "https://")):
        url = "https://" + url

    with httpx.Client(
        headers=browser_headers(),
        follow_redirects=True,
        timeout=httpx.Timeout(20.0, read=30.0),
    ) as client:
        response = client.get(url)
        response.raise_for_status()

        content_type = response.headers.get("content-type", "").lower()

        if content_type.startswith("image/"):
            host = urlparse(str(response.url)).netloc
            return str(response.url), host, host or "Источник"

        html = response.text[:2_000_000]
        final_url = str(response.url)

        image_url = _first_meta(
            html,
            [
                r'<meta[^>]+property=["\\\']og:image(?::secure_url)?["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']',
                r'<meta[^>]+content=["\\\']([^"\\\']+)["\\\'][^>]+property=["\\\']og:image(?::secure_url)?["\\\']',
                r'<meta[^>]+name=["\\\']twitter:image(?::src)?["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']',
                r'<meta[^>]+content=["\\\']([^"\\\']+)["\\\'][^>]+name=["\\\']twitter:image(?::src)?["\\\']',
                r'<link[^>]+rel=["\\\']image_src["\\\'][^>]+href=["\\\']([^"\\\']+)["\\\']',
            ],
        )

        if not image_url:
            # Common JSON-LD / embedded product schema.
            image_url = _first_meta(
                html,
                [
                    r'"image"\s*:\s*"([^"]+)"',
                    r'"image"\s*:\s*\[\s*"([^"]+)"',
                ],
            )

        if not image_url:
            # Last-resort first large-looking image URL.
            candidates = re.findall(
                r'<img[^>]+(?:src|data-src)=["\\\']([^"\\\']+)["\\\']',
                html,
                flags=re.IGNORECASE,
            )
            for candidate in candidates:
                low = candidate.lower()
                if any(x in low for x in ("logo", "icon", "avatar", "sprite")):
                    continue
                image_url = candidate
                break

        if not image_url:
            raise RuntimeError("На странице не найдено фото товара")

        image_url = urljoin(final_url, unescape(image_url))

        title = _first_meta(
            html,
            [
                r'<meta[^>]+property=["\\\']og:title["\\\'][^>]+content=["\\\']([^"\\\']+)["\\\']',
                r'<title[^>]*>(.*?)</title>',
            ],
        ) or "Товар по ссылке"
        title = re.sub(r"\s+", " ", unescape(title)).strip()[:120]

        host = urlparse(final_url).netloc.replace("www.", "")
        source_name = host.split(".")[0].capitalize() if host else "Источник"

        return image_url, title, source_name


def download_product_image(image_url: str, destination: Path) -> None:
    with httpx.Client(
        headers=browser_headers(),
        follow_redirects=True,
        timeout=httpx.Timeout(20.0, read=60.0),
    ) as client:
        response = client.get(image_url)
        response.raise_for_status()
        content_type = response.headers.get("content-type", "").lower()
        if "image" not in content_type:
            raise RuntimeError(f"Ссылка на фото вернула {content_type or 'неизвестный тип'}")
        if len(response.content) > 15 * 1024 * 1024:
            raise RuntimeError("Фото товара слишком большое")
        destination.write_bytes(response.content)




def _profile_width_factor(
    y: float,
    *,
    weight: float,
    chest: float,
    waist: float,
    hips: float,
) -> float:
    weight_factor = max(0.90, min((weight / 74.0) ** 0.22, 1.14))
    chest_factor = max(0.88, min(weight_factor * (chest / 96.0) ** 0.48, 1.16))
    waist_factor = max(0.88, min(weight_factor * (waist / 81.0) ** 0.50, 1.17))
    hips_factor = max(0.88, min(weight_factor * (hips / 94.0) ** 0.50, 1.17))
    legs_factor = max(0.90, min(weight_factor * (0.78 + 0.25 * hips_factor), 1.13))

    anchors = [
        (0.00, 1.00),
        (0.16, 1.00),
        (0.31, chest_factor),
        (0.45, waist_factor),
        (0.59, hips_factor),
        (0.78, legs_factor),
        (1.00, max(0.92, min(legs_factor * 0.96, 1.10))),
    ]

    for i in range(len(anchors) - 1):
        y0, f0 = anchors[i]
        y1, f1 = anchors[i + 1]
        if y0 <= y <= y1:
            t = (y - y0) / max(0.0001, y1 - y0)
            return f0 + (f1 - f0) * t

    return anchors[-1][1]


def prepare_person_for_tryon(
    source_path: Path,
    destination_path: Path,
    *,
    body_height: float,
    body_weight: float,
    body_chest: float,
    body_waist: float,
    body_hips: float,
) -> tuple[Path, dict[str, Any]]:
    height = max(145.0, min(float(body_height), 210.0))
    weight = max(40.0, min(float(body_weight), 140.0))
    chest = max(70.0, min(float(body_chest), 140.0))
    waist = max(55.0, min(float(body_waist), 130.0))
    hips = max(70.0, min(float(body_hips), 150.0))

    unchanged = (
        abs(height - 178.0) < 0.5
        and abs(weight - 74.0) < 0.5
        and abs(chest - 96.0) < 0.5
        and abs(waist - 81.0) < 0.5
        and abs(hips - 94.0) < 0.5
    )
    if unchanged:
        return source_path, {
            "body_warped": False,
            "height": height,
            "weight": weight,
            "chest": chest,
            "waist": waist,
            "hips": hips,
        }

    image = ImageOps.exif_transpose(Image.open(source_path)).convert("RGB")
    width, original_h = image.size
    background = _average_corner_color(image)

    height_factor = max(0.92, min(height / 178.0, 1.08))
    scaled_h = max(1, int(original_h * height_factor))
    scaled = image.resize((width, scaled_h), Image.Resampling.LANCZOS)

    vertical = Image.new("RGB", (width, original_h), background)
    if scaled_h >= original_h:
        top = (scaled_h - original_h) // 2
        vertical.paste(scaled.crop((0, top, width, top + original_h)), (0, 0))
    else:
        top = (original_h - scaled_h) // 2
        vertical.paste(scaled, (0, top))

    output = Image.new("RGB", (width, original_h), background)
    strip_h = max(3, original_h // 180)

    for y0 in range(0, original_h, strip_h):
        y1 = min(original_h, y0 + strip_h)
        y_norm = ((y0 + y1) / 2) / original_h
        factor = _profile_width_factor(
            y_norm,
            weight=weight,
            chest=chest,
            waist=waist,
            hips=hips,
        )
        factor = max(0.90, min(factor, 1.14))

        strip = vertical.crop((0, y0, width, y1))
        target_w = max(1, int(width * factor))
        strip = strip.resize((target_w, y1 - y0), Image.Resampling.BILINEAR)

        if target_w >= width:
            left = (target_w - width) // 2
            output.paste(strip.crop((left, 0, left + width, y1 - y0)), (0, y0))
        else:
            left = (width - target_w) // 2
            output.paste(strip, (left, y0))

    output.save(destination_path, format="JPEG", quality=95)

    return destination_path, {
        "body_warped": True,
        "height": height,
        "weight": weight,
        "chest": chest,
        "waist": waist,
        "hips": hips,
        "height_factor": round(height_factor, 3),
    }


COLOR_RGB: dict[str, tuple[int, int, int]] = {
    "Чёрный": (24, 24, 24),
    "Белый": (238, 238, 238),
    "Серый": (126, 126, 126),
    "Синий": (52, 88, 170),
    "Красный": (190, 53, 53),
    "Жёлтый": (213, 173, 50),
    "Зелёный": (65, 139, 91),
    "Бежевый": (204, 171, 129),
}

SIZE_SCALE: dict[str, float] = {
    "XS": 0.92,
    "S": 0.96,
    "M": 1.00,
    "L": 1.04,
    "XL": 1.08,
    "XXL": 1.12,
}

FIT_WIDTH_SCALE: dict[str, float] = {
    "Slim": 0.92,
    "Regular": 1.00,
    "Oversize": 1.12,
}

FIT_HEIGHT_SCALE: dict[str, float] = {
    "Slim": 0.98,
    "Regular": 1.00,
    "Oversize": 1.06,
}


def _average_corner_color(image: Image.Image) -> tuple[int, int, int]:
    rgb = image.convert("RGB")
    w, h = rgb.size
    sample = max(6, min(w, h) // 24)

    boxes = [
        (0, 0, sample, sample),
        (w - sample, 0, w, sample),
        (0, h - sample, sample, h),
        (w - sample, h - sample, w, h),
    ]

    values: list[tuple[int, int, int]] = []
    for box in boxes:
        crop = rgb.crop(box).resize((1, 1), Image.Resampling.BOX)
        values.append(crop.getpixel((0, 0)))

    return tuple(
        int(sum(value[channel] for value in values) / len(values))
        for channel in range(3)
    )


def _garment_mask(image: Image.Image) -> tuple[Image.Image, tuple[int, int, int]]:
    rgba = image.convert("RGBA")
    rgb = rgba.convert("RGB")
    background = _average_corner_color(rgb)

    bg = Image.new("RGB", rgb.size, background)
    difference = ImageChops.difference(rgb, bg)

    # Max RGB difference is more reliable than average grayscale difference
    # for coloured garments on white/neutral product backgrounds.
    r, g, b = difference.split()
    max_diff = ImageChops.lighter(ImageChops.lighter(r, g), b)
    hard = max_diff.point(lambda p: 255 if p >= 22 else 0)

    alpha = rgba.getchannel("A")
    if alpha.getextrema()[0] < 250:
        alpha_hard = alpha.point(lambda p: 255 if p >= 16 else 0)
        hard = ImageChops.lighter(hard, alpha_hard)

    # Clean small holes/noise and use a soft border for nicer recolouring.
    hard = hard.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(3))
    soft = hard.filter(ImageFilter.GaussianBlur(1.2))
    return soft, background


def _recolor_preserving_shading(
    rgb: Image.Image,
    mask: Image.Image,
    color_name: str,
) -> Image.Image:
    target = COLOR_RGB.get(color_name)
    if target is None:
        return rgb

    gray = ImageOps.grayscale(rgb)
    gray = ImageEnhance.Contrast(gray).enhance(0.85)

    if color_name == "Чёрный":
        dark = (6, 6, 6)
        light = (88, 88, 88)
    elif color_name == "Белый":
        dark = (105, 105, 105)
        light = (250, 250, 250)
    else:
        dark = tuple(max(0, int(channel * 0.22)) for channel in target)
        light = tuple(
            min(255, int(channel + (255 - channel) * 0.36))
            for channel in target
        )

    coloured = ImageOps.colorize(gray, black=dark, white=light)
    return Image.composite(coloured, rgb, mask)


def prepare_garment_for_tryon(
    source_path: Path,
    destination_path: Path,
    *,
    selected_color: str,
    selected_size: str,
    selected_fit: str,
) -> tuple[Path, dict[str, Any]]:
    """
    MVP visual controls:
    - colour: real pixel recolouring while preserving light/shadow;
    - size/fit: approximate flat-lay silhouette scaling before FASHN.

    This is intentionally described as approximate. It is not a brand sizing engine.
    """
    selected_color = (selected_color or "Как на фото").strip()
    selected_size = (selected_size or "M").strip().upper()
    selected_fit = (selected_fit or "Regular").strip().title()

    if (
        selected_color == "Как на фото"
        and selected_size == "M"
        and selected_fit == "Regular"
    ):
        return source_path, {
            "preprocessed": False,
            "color_applied": False,
            "size_scale": 1.0,
            "fit_width_scale": 1.0,
            "fit_height_scale": 1.0,
        }

    source = ImageOps.exif_transpose(Image.open(source_path)).convert("RGBA")
    rgb = source.convert("RGB")
    mask, background = _garment_mask(source)

    bbox = mask.point(lambda p: 255 if p >= 64 else 0).getbbox()
    if bbox is None:
        # If segmentation failed, do not destroy the garment image.
        source.convert("RGB").save(destination_path, quality=95)
        return destination_path, {
            "preprocessed": True,
            "mask_found": False,
            "color_applied": False,
            "size_scale": 1.0,
            "fit_width_scale": 1.0,
            "fit_height_scale": 1.0,
        }

    edited = _recolor_preserving_shading(rgb, mask, selected_color)

    size_scale = SIZE_SCALE.get(selected_size, 1.0)
    fit_width = FIT_WIDTH_SCALE.get(selected_fit, 1.0)
    fit_height = FIT_HEIGHT_SCALE.get(selected_fit, 1.0)

    width_scale = size_scale * fit_width
    height_scale = size_scale * fit_height

    # Keep the edited object inside the same canvas.
    w, h = edited.size
    x0, y0, x1, y1 = bbox
    crop = edited.crop(bbox)
    crop_mask = mask.crop(bbox)

    target_w = max(1, int(crop.width * width_scale))
    target_h = max(1, int(crop.height * height_scale))

    max_w = max(1, int(w * 0.94))
    max_h = max(1, int(h * 0.94))
    fit_inside = min(1.0, max_w / target_w, max_h / target_h)
    target_w = max(1, int(target_w * fit_inside))
    target_h = max(1, int(target_h * fit_inside))

    crop = crop.resize((target_w, target_h), Image.Resampling.LANCZOS)
    crop_mask = crop_mask.resize((target_w, target_h), Image.Resampling.LANCZOS)

    canvas = Image.new("RGB", (w, h), background)

    original_center_x = (x0 + x1) // 2
    original_center_y = (y0 + y1) // 2
    paste_x = max(0, min(w - target_w, original_center_x - target_w // 2))
    paste_y = max(0, min(h - target_h, original_center_y - target_h // 2))

    canvas.paste(crop, (paste_x, paste_y), crop_mask)
    canvas.save(destination_path, format="PNG", optimize=True)

    return destination_path, {
        "preprocessed": True,
        "mask_found": True,
        "color_applied": selected_color in COLOR_RGB,
        "selected_color": selected_color,
        "selected_size": selected_size,
        "selected_fit": selected_fit,
        "size_scale": size_scale,
        "fit_width_scale": fit_width,
        "fit_height_scale": fit_height,
        "final_width_scale": round(width_scale, 3),
        "final_height_scale": round(height_scale, 3),
    }


# --------------------------------------------------------------------------- #
# Generation: one FASHN call = one garment. An outfit is a chain of calls where
# each next garment is put on the previous result.
# --------------------------------------------------------------------------- #
OUTFIT_ORDER = {"lower_body": 0, "dresses": 1, "upper_body": 2}
MAX_OUTFIT_ITEMS = 3
GARMENT_PHOTO_TYPES = {"flat-lay", "model", "auto"}


def order_outfit(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Bottoms first, then dresses, then tops/outerwear (stable inside a category)."""
    return sorted(items, key=lambda it: OUTFIT_ORDER.get(it["category"], 9))


def generate_remote(
    remote_url: str,
    person_path: Path,
    garment_path: Path,
    category: str,
    photo_type: str,
    steps: int,
    seed: int,
) -> bytes:
    """FASHN on Kaggle or on the local GPU server (same async /jobs API).
    The local server returns a full-resolution JPEG (crop + paste-back + upscale)."""
    with person_path.open("rb") as person_file, garment_path.open("rb") as garment_file:
        create = httpx.post(
            f"{remote_url}/jobs",
            data={
                "category": fashn_category(category),
                "garment_photo_type": photo_type,
                "num_timesteps": str(steps),
                "guidance_scale": "1.5",
                "seed": str(seed),
                "segmentation_free": "true",
            },
            files={
                "person_photo": (person_path.name, person_file, image_mime(person_path)),
                "garment_photo": (garment_path.name, garment_file, image_mime(garment_path)),
            },
            timeout=httpx.Timeout(connect=30.0, read=45.0, write=120.0, pool=30.0),
            follow_redirects=True,
        )
    if create.status_code not in {200, 201, 202}:
        raise RuntimeError(f"GPU job create HTTP {create.status_code}")
    remote_job_id = str(create.json().get("job_id") or "")
    if not remote_job_id:
        raise RuntimeError("GPU server did not return job_id")

    deadline = time.time() + 12 * 60
    while time.time() < deadline:
        poll = httpx.get(f"{remote_url}/jobs/{remote_job_id}", timeout=20.0, follow_redirects=True)
        if poll.status_code != 200:
            raise RuntimeError(f"GPU status HTTP {poll.status_code}")
        state = poll.json()
        remote_status = str(state.get("status") or "unknown")
        if remote_status == "completed":
            result = httpx.get(
                f"{remote_url}/jobs/{remote_job_id}/result",
                timeout=httpx.Timeout(connect=20.0, read=120.0, write=30.0, pool=20.0),
                follow_redirects=True,
            )
            content_type = result.headers.get("content-type", "").lower()
            if result.status_code != 200 or "image" not in content_type:
                raise RuntimeError(f"GPU result HTTP {result.status_code}")
            return result.content
        if remote_status == "failed":
            raise RuntimeError(str(state.get("error") or "FASHN generation failed")[:500])
        time.sleep(1.5)
    raise RuntimeError("GPU generation timeout after 12 minutes")


def generate_hf(
    person_path: Path,
    garment_path: Path,
    category: str,
    photo_type: str,
    steps: int,
    seed: int,
) -> bytes:
    from .hf_space import fashn_try_on

    if photo_type == "auto":
        photo_type = "flat-lay"
    return fashn_try_on(
        HF_SPACE_ID,
        hf_token(),
        person_path,
        garment_path,
        fashn_category(category),
        steps=steps,
        garment_photo_type=photo_type,
        seed=seed,
    )


def run_outfit_job(
    job_id: str,
    provider: str,
    person_path: Path,
    items: list[dict[str, Any]],
    steps: int,
    seed: int,
) -> None:
    from .hf_space import QuotaExceeded

    job = JOBS[job_id]
    job["status"] = "processing"
    job["started_at"] = utc_now_iso()
    current_person = person_path
    remote_url = get_remote_url()

    try:
        for index, item in enumerate(items):
            job["step"] = index + 1
            job["step_label"] = item.get("label") or categoryRu_py(item["category"])
            job["step_started_at"] = utc_now_iso()

            if provider.startswith("space:"):
                from .hf_space import space_try_on

                png = space_try_on(provider.split(":", 1)[1], hf_token(), current_person,
                                   item["prepared_path"], item["category"], steps, seed, item["photo_type"])
            elif provider == "hf_space":
                png = generate_hf(current_person, item["prepared_path"], item["category"],
                                  item["photo_type"], steps, seed)
            else:
                if not remote_url:
                    raise RuntimeError("GPU server URL is not configured")
                png = generate_remote(remote_url, current_person, item["prepared_path"],
                                      item["category"], item["photo_type"], steps, seed)

            ext = ".jpg" if png[:3] == b"\xff\xd8\xff" else ".png"
            step_path = GENERATED_DIR / f"{job_id}_step{index + 1}{ext}"
            step_path.write_bytes(png)
            job["step_results"].append(f"/generated/{step_path.name}")
            current_person = step_path

        job["status"] = "completed"
        job["result_url"] = job["step_results"][-1]
        job["completed_at"] = utc_now_iso()
    except QuotaExceeded as exc:
        job["status"] = "failed"
        job["error"] = (
            "Дневной лимит бесплатного GPU Hugging Face исчерпан"
            + ("" if hf_token() else " (без HF-токена лимит ещё меньше — запустите SET_HF_TOKEN.bat)")
            + f". Выберите модель «FASHN VTON 1.5» на ноутбуке или попробуйте завтра. ({str(exc)[:160]})"
        )
    except Exception as exc:
        job["status"] = "failed"
        step = job.get("step") or 1
        job["error"] = f"{job.get('engine') or ENGINE}, шаг {step}: {type(exc).__name__}: {str(exc)[:600]}"


def categoryRu_py(category: str) -> str:
    return {"upper_body": "Верх", "lower_body": "Низ", "dresses": "Платье"}.get(category, "Вещь")


@app.get("/")
def root():
    return {
        "app": "FitMe AI CLEAN MVP",
        "version": APP_VERSION,
        "docs": "/docs",
    }


@app.post("/api/v1/avatar/cutout")
async def avatar_cutout(photo: UploadFile = File(...)):
    raw = await photo.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty avatar photo")
    if len(raw) > 20 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Avatar photo is too large")

    try:
        from rembg import remove

        session = _get_human_cutout_session()
        result = remove(
            raw,
            session=session,
            alpha_matting=True,
            alpha_matting_foreground_threshold=235,
            alpha_matting_background_threshold=15,
            alpha_matting_erode_size=8,
        )
        result = _trim_transparent_person(result)
        return Response(
            content=result,
            media_type="image/png",
            headers={
                "Cache-Control": "no-store",
                "X-FitMe-Cutout": "u2net_human_seg",
            },
        )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=f"AI cutout failed: {type(exc).__name__}: {str(exc)[:300]}",
        ) from exc


@app.get("/health")
def health():
    return {
        "app": "FitMe AI",
        "status": "online",
        "version": APP_VERSION,
        "api_key_required": bool(API_KEY),
        "max_outfit_items": MAX_OUTFIT_ITEMS,
        "provider_mode": PROVIDER_MODE,
        "engine": ENGINE,
        "steps": FASHN_STEPS,
        "remote_configured": bool(get_remote_url()),
        "hf_space": HF_SPACE_ID,
    }


@app.get("/api/v1/ai/status")
def ai_status():
    provider, online, details, error = resolve_provider()
    return {
        "provider": provider,
        "engine": ENGINE,
        "steps": HF_STEPS if provider == "hf_space" else FASHN_STEPS,
        "real_ai": True,
        "online": online,
        "remote_ai_online": online,
        "remote_url_configured": bool(get_remote_url()),
        "ai": details,
        "error": error,
        "engines": {
            "upper_body": ENGINE,
            "lower_body": ENGINE,
            "dresses": ENGINE,
        },
    }


_MODELS_CACHE: dict[str, Any] = {"at": 0.0, "items": None}
_MODELS_LOCK = threading.Lock()


def _space_stage(space_id: str) -> tuple[bool, str | None]:
    from .hf_space import HFSpace

    space = HFSpace(space_id, hf_token())
    try:
        return space.status()
    finally:
        space.close()


@app.get("/api/v1/models")
def list_models(refresh: bool = False):
    """Models for the app's chooser with live availability (cached for 5 minutes)."""
    with _MODELS_LOCK:
        if not refresh and _MODELS_CACHE["items"] is not None and time.time() - _MODELS_CACHE["at"] < 300:
            return {"items": _MODELS_CACHE["items"], "hf_token": bool(hf_token()), "cached": True}

    from concurrent.futures import ThreadPoolExecutor

    from .hf_space import SPACE_MODELS

    def check(m: dict[str, Any]) -> dict[str, Any]:
        item = dict(m)
        try:
            if m["id"] == "fashn":
                _, online, details, error = resolve_provider(timeout=6.0)
                item["available"] = online
                item["reason"] = None if online else "Запустите START_LOCAL_GPU.bat на ноутбуке"
                item["upscaler"] = bool((details or {}).get("upscaler"))
            else:
                online, error = _space_stage(SPACE_MODELS[m["id"]][0])
                item["available"] = online
                item["reason"] = None if online else (error or "Space недоступен")
                item["needs_token"] = not hf_token()
        except Exception as exc:
            item["available"] = False
            item["reason"] = f"{type(exc).__name__}: {str(exc)[:120]}"
        return item

    with ThreadPoolExecutor(max_workers=len(MODEL_CATALOG)) as pool:
        items = list(pool.map(check, MODEL_CATALOG))
    with _MODELS_LOCK:
        _MODELS_CACHE.update(at=time.time(), items=items)
    return {"items": items, "hf_token": bool(hf_token()), "cached": False}


@app.get("/api/v1/catalog")
def get_catalog():
    return {"items": load_json_list(CATALOG_FILE)}


@app.post("/api/v1/catalog/import-url")
def import_catalog_url(payload: ImportUrlPayload):
    if payload.category not in VALID_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid garment category")

    source_url = payload.source_url.strip()
    if not source_url:
        raise HTTPException(status_code=422, detail="source_url is required")

    try:
        image_url, title, source_name = discover_product_image(source_url)
        item_id = uuid.uuid4().hex[:10]
        file_name = f"{item_id}.jpg"
        destination = CATALOG_DIR / file_name
        download_product_image(image_url, destination)
    except Exception as exc:
        raise HTTPException(
            status_code=422,
            detail=f"Не удалось найти фото товара: {type(exc).__name__}: {str(exc)[:300]}",
        )

    normalized_source = source_url
    if not normalized_source.startswith(("http://", "https://")):
        normalized_source = "https://" + normalized_source

    item = {
        "item_id": item_id,
        "name": title or "Товар по ссылке",
        "category": payload.category,
        "description": title or "garment",
        "image_url": f"/catalog/{file_name}",
        "file_name": file_name,
        "source_name": source_name,
        "source_url": normalized_source,
        "created_at": utc_now_iso(),
    }

    items = load_json_list(CATALOG_FILE)
    items.insert(0, item)
    save_json_list(CATALOG_FILE, items)

    return {
        "status": "saved",
        "item": item,
        "detected_image_url": image_url,
    }


@app.post("/api/v1/catalog/upload")
async def upload_catalog_item(
    name: str = Form(...),
    category: str = Form(...),
    description: str = Form(""),
    source_name: str = Form(""),
    source_url: str = Form(""),
    garment_photo: UploadFile = File(...),
):
    if category not in VALID_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid garment category")

    item_id = uuid.uuid4().hex[:10]
    suffix = suffix_for(garment_photo)
    file_name = f"{item_id}{suffix}"
    (CATALOG_DIR / file_name).write_bytes(await garment_photo.read())

    item = {
        "item_id": item_id,
        "name": name.strip() or "Garment",
        "category": category,
        "description": description.strip() or name.strip() or "garment",
        "image_url": f"/catalog/{file_name}",
        "file_name": file_name,
        "source_name": source_name.strip(),
        "source_url": source_url.strip(),
        "created_at": utc_now_iso(),
    }

    items = load_json_list(CATALOG_FILE)
    items.insert(0, item)
    save_json_list(CATALOG_FILE, items)
    return {"status": "saved", "item": item}


@app.delete("/api/v1/catalog/{item_id}")
def delete_catalog_item(item_id: str):
    items = load_json_list(CATALOG_FILE)
    found = next((x for x in items if x.get("item_id") == item_id), None)
    if not found:
        raise HTTPException(status_code=404, detail="Catalog item not found")

    file_name = found.get("file_name")
    if file_name:
        try:
            (CATALOG_DIR / str(file_name)).unlink(missing_ok=True)
        except Exception:
            pass

    save_json_list(
        CATALOG_FILE,
        [x for x in items if x.get("item_id") != item_id],
    )
    return {"status": "deleted", "item_id": item_id}


def _clamp_steps(value: int | None, provider: str) -> int:
    default = HF_STEPS if provider == "hf_space" else FASHN_STEPS
    if value is None or value <= 0:
        return default
    return max(10, min(int(value), 50))


def _catalog_item(item_id: str) -> dict[str, Any]:
    item = next((x for x in load_json_list(CATALOG_FILE) if x.get("item_id") == item_id), None)
    if not item:
        raise HTTPException(status_code=404, detail="Catalog item not found")
    return item


def _prepare_person(job_id: str, person_path: Path, body: dict[str, float]) -> tuple[Path, dict[str, Any]]:
    if not BODY_WARP:
        return person_path, {"body_warped": False, "reason": "disabled (keeps the photo sharp)"}
    try:
        return prepare_person_for_tryon(
            person_path,
            UPLOAD_DIR / f"{job_id}_person_profile.jpg",
            body_height=body["height"],
            body_weight=body["weight"],
            body_chest=body["chest"],
            body_waist=body["waist"],
            body_hips=body["hips"],
        )
    except Exception as exc:
        return person_path, {"body_warped": False, "fallback": True, "error": f"{type(exc).__name__}: {str(exc)[:240]}"}


def _prepare_garment(job_id: str, index: int, garment_path: Path, color: str, size: str, fit: str) -> tuple[Path, dict[str, Any]]:
    if color == "Как на фото" and size.upper() == "M" and fit.title() == "Regular":
        return garment_path, {"preprocessed": False}
    try:
        return prepare_garment_for_tryon(
            garment_path,
            UPLOAD_DIR / f"{job_id}_prepared_{index}.png",
            selected_color=color,
            selected_size=size,
            selected_fit=fit,
        )
    except Exception as exc:
        return garment_path, {"preprocessed": False, "fallback": True, "error": f"{type(exc).__name__}: {str(exc)[:240]}"}


async def _start_job(
    *,
    person_photo: UploadFile,
    items: list[dict[str, Any]],
    uploads: list[UploadFile],
    body: dict[str, float],
    color: str,
    size: str,
    fit: str,
    gender: str,
    steps: int | None,
    seed: int | None,
    title: str,
    model: str = "fashn",
) -> dict[str, Any]:
    """items: [{"category", "photo_type", "label", "catalog_item_id"? | "upload_index"?}]"""
    if not items:
        raise HTTPException(status_code=422, detail="Добавь хотя бы одну вещь")
    if len(items) > MAX_OUTFIT_ITEMS:
        raise HTTPException(status_code=422, detail=f"Максимум {MAX_OUTFIT_ITEMS} вещи за одну примерку")

    model = (model or "fashn").strip()
    if model not in MODEL_IDS:
        raise HTTPException(status_code=422, detail=f"Неизвестная модель: {model}")
    info = model_info(model)
    unsupported = [str(raw.get("category")) for raw in items if str(raw.get("category")) not in info["categories"]]
    if unsupported:
        raise HTTPException(
            status_code=422,
            detail=f"{info['title']} умеет только: {', '.join(categoryRu_py(c) for c in info['categories'])}. "
                   "Уберите лишние вещи или выберите другую модель.",
        )

    if model == "fashn":
        provider, online, _, status_error = resolve_provider(timeout=10.0)
        if not online:
            raise HTTPException(
                status_code=503,
                detail=f"AI сервер недоступен. {status_error or ''} Запусти GPU-сервер на компьютере.",
            )
    else:
        provider = f"space:{model}"

    job_id = uuid.uuid4().hex[:10]
    person_path = UPLOAD_DIR / f"{job_id}_person{suffix_for(person_photo)}"
    person_path.write_bytes(await person_photo.read())

    prepared_items: list[dict[str, Any]] = []
    first_source = {"source_name": "", "source_url": ""}
    for index, raw in enumerate(items):
        category = str(raw.get("category") or "upper_body")
        photo_type = str(raw.get("photo_type") or "auto")
        if category not in VALID_CATEGORIES:
            raise HTTPException(status_code=422, detail="Invalid garment category")
        if photo_type not in GARMENT_PHOTO_TYPES:
            photo_type = "auto"

        if raw.get("catalog_item_id"):
            cat = _catalog_item(str(raw["catalog_item_id"]))
            category = str(cat.get("category") or category)
            garment_path = CATALOG_DIR / str(cat["file_name"])
            garment_url = str(cat["image_url"])
            label = str(raw.get("label") or cat.get("name") or categoryRu_py(category))
            if index == 0:
                first_source = {"source_name": str(cat.get("source_name") or ""), "source_url": str(cat.get("source_url") or "")}
        else:
            upload_index = int(raw.get("upload_index", -1))
            if not 0 <= upload_index < len(uploads):
                raise HTTPException(status_code=422, detail="garment photo is missing")
            upload = uploads[upload_index]
            garment_path = UPLOAD_DIR / f"{job_id}_garment{index}{suffix_for(upload)}"
            garment_path.write_bytes(await upload.read())
            garment_url = f"/uploads/{garment_path.name}"
            label = str(raw.get("label") or categoryRu_py(category))

        # Colour only makes sense for a single garment; size/fit apply to every item.
        item_color = color if len(items) == 1 else "Как на фото"
        prepared_path, prep = _prepare_garment(job_id, index, garment_path, item_color, size, fit)
        prepared_items.append({
            "category": category,
            "photo_type": photo_type,
            "label": label,
            "garment_url": garment_url,
            "prepared_path": prepared_path,
            "preprocessing": prep,
        })

    ordered = order_outfit(prepared_items)
    prepared_person, body_prep = _prepare_person(job_id, person_path, body)
    num_steps = _clamp_steps(steps, provider)
    used_seed = int(seed) if seed is not None and seed >= 0 else 42

    JOBS[job_id] = {
        "job_id": job_id,
        "status": "queued",
        "provider": provider,
        "model": model,
        "engine": info["title"],
        "category": ordered[-1]["category"] if len(ordered) == 1 else "outfit",
        "garment_description": title or " + ".join(it["label"] for it in ordered),
        "created_at": utc_now_iso(),
        "person_url": f"/uploads/{person_path.name}",
        "body_profile": body,
        "body_preprocessing": body_prep,
        "garment_url": ordered[0]["garment_url"],
        "items": [
            {"label": it["label"], "category": it["category"], "photo_type": it["photo_type"],
             "garment_url": it["garment_url"], "preprocessing": it["preprocessing"]}
            for it in ordered
        ],
        "total_steps": len(ordered),
        "step": 0,
        "step_label": None,
        "step_results": [],
        "num_timesteps": num_steps,
        "seed": used_seed,
        "gender": gender,
        "size": size,
        "fit": fit,
        "color": color,
        "source_name": first_source["source_name"],
        "source_url": first_source["source_url"],
        "result_url": None,
        "error": None,
    }

    threading.Thread(
        target=run_outfit_job,
        args=(job_id, provider, prepared_person, ordered, num_steps, used_seed),
        daemon=True,
        name=f"fitme-{job_id}",
    ).start()
    return JOBS[job_id]


@app.post("/api/v1/try-on/upload")
async def create_try_on(
    garment_description: str = Form("garment"),
    category: str = Form(...),
    selected_color: str = Form("Как на фото"),
    selected_size: str = Form("M"),
    selected_fit: str = Form("Regular"),
    selected_gender: str = Form("Унисекс"),
    body_height: float = Form(178.0),
    body_weight: float = Form(74.0),
    body_chest: float = Form(96.0),
    body_waist: float = Form(81.0),
    body_hips: float = Form(94.0),
    garment_photo_type: str = Form("flat-lay"),
    num_steps: int | None = Form(None),
    seed: int | None = Form(None),
    person_photo: UploadFile = File(...),
    garment_photo: UploadFile | None = File(None),
    catalog_item_id: str | None = Form(None),
    model: str = Form("fashn"),
):
    """Single garment (kept for older app builds)."""
    item: dict[str, Any] = {"category": category, "photo_type": garment_photo_type, "label": garment_description}
    uploads: list[UploadFile] = []
    if catalog_item_id:
        item["catalog_item_id"] = catalog_item_id
    elif garment_photo is not None:
        uploads.append(garment_photo)
        item["upload_index"] = 0
    else:
        raise HTTPException(status_code=422, detail="garment_photo or catalog_item_id is required")
    return await _start_job(
        person_photo=person_photo,
        items=[item],
        uploads=uploads,
        body={"height": body_height, "weight": body_weight, "chest": body_chest, "waist": body_waist, "hips": body_hips},
        color=selected_color,
        size=selected_size,
        fit=selected_fit,
        gender=selected_gender,
        steps=num_steps,
        seed=seed,
        title=garment_description,
        model=model,
    )


@app.post("/api/v1/try-on/outfit")
async def create_outfit_try_on(
    items: str = Form(...),
    selected_color: str = Form("Как на фото"),
    selected_size: str = Form("M"),
    selected_fit: str = Form("Regular"),
    selected_gender: str = Form("Унисекс"),
    body_height: float = Form(178.0),
    body_weight: float = Form(74.0),
    body_chest: float = Form(96.0),
    body_waist: float = Form(81.0),
    body_hips: float = Form(94.0),
    num_steps: int | None = Form(None),
    seed: int | None = Form(None),
    title: str = Form(""),
    model: str = Form("fashn"),
    person_photo: UploadFile = File(...),
    garment_photos: list[UploadFile] = File(default=[]),
):
    """Up to 3 garments put on one after another (bottoms → dresses → tops)."""
    try:
        parsed = json.loads(items)
        if not isinstance(parsed, list):
            raise ValueError("items must be a list")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Bad items JSON: {exc}") from exc
    return await _start_job(
        person_photo=person_photo,
        items=parsed,
        uploads=garment_photos,
        body={"height": body_height, "weight": body_weight, "chest": body_chest, "waist": body_waist, "hips": body_hips},
        color=selected_color,
        size=selected_size,
        fit=selected_fit,
        gender=selected_gender,
        steps=num_steps,
        seed=seed,
        title=title,
        model=model,
    )


@app.get("/api/v1/try-on/{job_id}")
def get_try_on(job_id: str):
    return JOBS.get(job_id) or {"job_id": job_id, "status": "not_found"}


@app.post("/api/v1/looks/save")
def save_look(payload: SaveLookPayload):
    job = JOBS.get(payload.job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.get("status") != "completed" or not job.get("result_url"):
        raise HTTPException(status_code=409, detail="Job is not completed")

    items = load_json_list(LOOKS_FILE)
    existing = next(
        (x for x in items if x.get("job_id") == payload.job_id),
        None,
    )
    if existing:
        return {"status": "already_saved", "look": existing}

    look = {
        "look_id": uuid.uuid4().hex[:10],
        "job_id": payload.job_id,
        "title": payload.title or job.get("garment_description") or "AI Look",
        "provider": job.get("provider"),
        "engine": job.get("engine"),
        "model": job.get("model") or "fashn",
        "num_timesteps": job.get("num_timesteps"),
        "category": job.get("category"),
        "created_at": utc_now_iso(),
        "person_url": job.get("person_url"),
        "garment_url": job.get("garment_url"),
        "source_name": job.get("source_name"),
        "source_url": job.get("source_url"),
        "gender": payload.gender or job.get("gender"),
        "size": payload.size or job.get("size"),
        "fit": payload.fit or job.get("fit"),
        "color": payload.color or job.get("color"),
        "result_url": job.get("result_url"),
        "items": job.get("items") or [],
        "total_steps": job.get("total_steps") or 1,
    }
    items.insert(0, look)
    save_json_list(LOOKS_FILE, items)
    return {"status": "saved", "look": look}


@app.get("/api/v1/looks")
def get_looks():
    return {"items": load_json_list(LOOKS_FILE)}


@app.delete("/api/v1/looks/{look_id}")
def delete_look(look_id: str):
    items = load_json_list(LOOKS_FILE)
    kept = [x for x in items if x.get("look_id") != look_id]
    if len(kept) == len(items):
        raise HTTPException(status_code=404, detail="Look not found")
    save_json_list(LOOKS_FILE, kept)
    return {"status": "deleted", "look_id": look_id}
