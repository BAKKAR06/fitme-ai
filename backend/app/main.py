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
APP_VERSION = "1.6.0-cloud"
# Provider: "auto" (Kaggle if its URL is set and online, otherwise Hugging Face Space),
# "kaggle" (only Kaggle), "hf_space" (only Hugging Face Space).
PROVIDER_MODE = os.getenv("FITME_AI_PROVIDER", "auto").strip().lower()
FASHN_STEPS = max(10, min(int(os.getenv("FITME_FASHN_STEPS", "10")), 50))
HF_SPACE_ID = os.getenv("FITME_HF_SPACE", "fashn-ai/fashn-vton-1.5").strip()
HF_TOKEN = (os.getenv("HF_TOKEN") or "").strip() or None
HF_STEPS = max(10, min(int(os.getenv("FITME_HF_STEPS", "30")), 50))
VALID_CATEGORIES = {"upper_body", "lower_body", "dresses"}

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

    space = HFSpace(HF_SPACE_ID, HF_TOKEN)
    try:
        ok, error = space.status()
    finally:
        space.close()
    return ok, {"space": HF_SPACE_ID, "token": bool(HF_TOKEN), "steps": HF_STEPS}, error


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


def run_hf_space(
    job_id: str,
    person_path: Path,
    garment_path: Path,
    category: str,
) -> None:
    from .hf_space import QuotaExceeded, fashn_try_on

    JOBS[job_id]["status"] = "processing"
    try:
        png = fashn_try_on(
            HF_SPACE_ID,
            HF_TOKEN,
            person_path,
            garment_path,
            fashn_category(category),
            steps=HF_STEPS,
        )
        output_name = f"{job_id}_fashn.png"
        (GENERATED_DIR / output_name).write_bytes(png)
        JOBS[job_id]["status"] = "completed"
        JOBS[job_id]["result_url"] = f"/generated/{output_name}"
        JOBS[job_id]["completed_at"] = utc_now_iso()
    except QuotaExceeded as exc:
        JOBS[job_id]["status"] = "failed"
        JOBS[job_id]["error"] = (
            "Дневной лимит бесплатного GPU Hugging Face исчерпан. "
            "Попробуй завтра или запусти Kaggle-ноутбук. "
            f"({str(exc)[:200]})"
        )
    except Exception as exc:
        JOBS[job_id]["status"] = "failed"
        JOBS[job_id]["error"] = f"{ENGINE} (HF Space): {type(exc).__name__}: {str(exc)[:600]}"


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


def run_remote_fashn(
    job_id: str,
    person_path: Path,
    garment_path: Path,
    category: str,
) -> None:
    JOBS[job_id]["status"] = "processing"
    remote_url = get_remote_url()

    try:
        if not remote_url:
            raise RuntimeError(
                "AI URL не настроен. Запусти START_FITME.bat и вставь URL из Kaggle."
            )

        # IMPORTANT: CLEAN MVP v2 uses a short POST that only creates a remote job.
        # The long GPU generation runs in Kaggle background, so Cloudflare no longer
        # has to keep one HTTP request open for several minutes.
        with (
            person_path.open("rb") as person_file,
            garment_path.open("rb") as garment_file,
        ):
            create_response = httpx.post(
                f"{remote_url}/jobs",
                data={
                    "category": fashn_category(category),
                    "garment_photo_type": "flat-lay",
                    "num_timesteps": str(FASHN_STEPS),
                    "guidance_scale": "1.5",
                    "seed": "42",
                    "segmentation_free": "true",
                },
                files={
                    "person_photo": (
                        person_path.name,
                        person_file,
                        image_mime(person_path),
                    ),
                    "garment_photo": (
                        garment_path.name,
                        garment_file,
                        image_mime(garment_path),
                    ),
                },
                timeout=httpx.Timeout(
                    connect=30.0,
                    read=45.0,
                    write=120.0,
                    pool=30.0,
                ),
                follow_redirects=True,
            )

        if create_response.status_code not in {200, 201, 202}:
            raise RuntimeError(
                f"Kaggle job create HTTP {create_response.status_code}"
            )

        remote_job = create_response.json()
        remote_job_id = str(remote_job.get("job_id") or "")
        if not remote_job_id:
            raise RuntimeError("Kaggle не вернул job_id")

        JOBS[job_id]["remote_job_id"] = remote_job_id

        # Poll with short requests. Each request is safely below Cloudflare timeout.
        deadline = time.time() + 12 * 60
        while time.time() < deadline:
            poll = httpx.get(
                f"{remote_url}/jobs/{remote_job_id}",
                timeout=20.0,
                follow_redirects=True,
            )
            if poll.status_code != 200:
                raise RuntimeError(
                    f"Kaggle status HTTP {poll.status_code}"
                )

            state = poll.json()
            remote_status = str(state.get("status") or "unknown")

            if remote_status == "completed":
                result = httpx.get(
                    f"{remote_url}/jobs/{remote_job_id}/result",
                    timeout=httpx.Timeout(
                        connect=20.0,
                        read=120.0,
                        write=30.0,
                        pool=20.0,
                    ),
                    follow_redirects=True,
                )
                if result.status_code != 200:
                    raise RuntimeError(
                        f"Kaggle result HTTP {result.status_code}"
                    )
                if "image" not in result.headers.get("content-type", "").lower():
                    raise RuntimeError("Kaggle result is not an image")

                output_name = f"{job_id}_fashn.png"
                (GENERATED_DIR / output_name).write_bytes(result.content)

                JOBS[job_id]["status"] = "completed"
                JOBS[job_id]["result_url"] = f"/generated/{output_name}"
                JOBS[job_id]["completed_at"] = utc_now_iso()
                return

            if remote_status == "failed":
                remote_error = str(state.get("error") or "FASHN generation failed")
                raise RuntimeError(remote_error[:500])

            time.sleep(2)

        raise RuntimeError("Kaggle generation timeout after 12 minutes")

    except Exception as exc:
        JOBS[job_id]["status"] = "failed"
        JOBS[job_id]["error"] = (
            f"{ENGINE}: {type(exc).__name__}: {str(exc)[:700]}"
        )


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
    person_photo: UploadFile = File(...),
    garment_photo: UploadFile | None = File(None),
    catalog_item_id: str | None = Form(None),
):
    if category not in VALID_CATEGORIES:
        raise HTTPException(status_code=422, detail="Invalid garment category")

    provider, online, _, status_error = resolve_provider(timeout=10.0)
    if not online:
        raise HTTPException(
            status_code=503,
            detail=(
                "AI сервер недоступен. "
                f"{status_error or ''} "
                "Запусти Kaggle-ноутбук или проверь Hugging Face Space."
            ),
        )

    job_id = uuid.uuid4().hex[:10]
    person_suffix = suffix_for(person_photo)
    person_path = UPLOAD_DIR / f"{job_id}_person{person_suffix}"
    person_path.write_bytes(await person_photo.read())

    source_name = ""
    source_url = ""

    if catalog_item_id:
        item = next(
            (
                x
                for x in load_json_list(CATALOG_FILE)
                if x.get("item_id") == catalog_item_id
            ),
            None,
        )
        if not item:
            raise HTTPException(status_code=404, detail="Catalog item not found")

        category = str(item.get("category") or category)
        garment_description = (
            garment_description.strip()
            or str(item.get("description") or "")
            or str(item.get("name") or "")
            or "garment"
        )
        garment_path = CATALOG_DIR / str(item["file_name"])
        garment_url = str(item["image_url"])
        source_name = str(item.get("source_name") or "")
        source_url = str(item.get("source_url") or "")
    else:
        if garment_photo is None:
            raise HTTPException(
                status_code=422,
                detail="garment_photo or catalog_item_id is required",
            )
        garment_suffix = suffix_for(garment_photo)
        garment_path = UPLOAD_DIR / f"{job_id}_garment{garment_suffix}"
        garment_path.write_bytes(await garment_photo.read())
        garment_url = f"/uploads/{garment_path.name}"

    prepared_person_path = person_path
    body_preprocessing: dict[str, Any] = {
        "body_warped": False,
        "height": body_height,
        "weight": body_weight,
        "chest": body_chest,
        "waist": body_waist,
        "hips": body_hips,
    }

    try:
        candidate_person_path = UPLOAD_DIR / f"{job_id}_person_profile.jpg"
        prepared_person_path, body_preprocessing = prepare_person_for_tryon(
            person_path,
            candidate_person_path,
            body_height=body_height,
            body_weight=body_weight,
            body_chest=body_chest,
            body_waist=body_waist,
            body_hips=body_hips,
        )
    except Exception as exc:
        prepared_person_path = person_path
        body_preprocessing = {
            "body_warped": False,
            "fallback": True,
            "error": f"{type(exc).__name__}: {str(exc)[:240]}",
        }

    prepared_garment_path = garment_path
    preprocessing: dict[str, Any] = {
        "preprocessed": False,
        "selected_color": selected_color,
        "selected_size": selected_size,
        "selected_fit": selected_fit,
    }

    if (
        selected_color != "Как на фото"
        or selected_size.upper() != "M"
        or selected_fit.title() != "Regular"
    ):
        prepared_garment_path = UPLOAD_DIR / f"{job_id}_prepared.png"
        try:
            prepared_garment_path, preprocessing = prepare_garment_for_tryon(
                garment_path,
                prepared_garment_path,
                selected_color=selected_color,
                selected_size=selected_size,
                selected_fit=selected_fit,
            )
        except Exception as exc:
            # Never block the real try-on because of optional MVP styling.
            # Fall back to the original garment image.
            prepared_garment_path = garment_path
            preprocessing = {
                "preprocessed": False,
                "fallback": True,
                "error": f"{type(exc).__name__}: {str(exc)[:240]}",
            }

    JOBS[job_id] = {
        "job_id": job_id,
        "status": "queued",
        "provider": provider,
        "engine": ENGINE,
        "category": category,
        "garment_description": garment_description,
        "created_at": utc_now_iso(),
        "person_url": f"/uploads/{person_path.name}",
        "prepared_person_url": (
            f"/uploads/{prepared_person_path.name}"
            if prepared_person_path.parent == UPLOAD_DIR
            else f"/uploads/{person_path.name}"
        ),
        "body_profile": {
            "height": body_height,
            "weight": body_weight,
            "chest": body_chest,
            "waist": body_waist,
            "hips": body_hips,
        },
        "body_preprocessing": body_preprocessing,
        "garment_url": garment_url,
        "prepared_garment_url": (
            f"/uploads/{prepared_garment_path.name}"
            if prepared_garment_path.parent == UPLOAD_DIR
            else garment_url
        ),
        "gender": selected_gender,
        "size": selected_size,
        "fit": selected_fit,
        "color": selected_color,
        "preprocessing": preprocessing,
        "source_name": source_name,
        "source_url": source_url,
        "result_url": None,
        "error": None,
    }

    threading.Thread(
        target=run_hf_space if provider == "hf_space" else run_remote_fashn,
        args=(job_id, prepared_person_path, prepared_garment_path, category),
        daemon=True,
        name=f"fitme-{job_id}",
    ).start()

    return JOBS[job_id]


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
