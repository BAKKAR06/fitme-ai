"""Re-colour a garment on a finished try-on picture, keeping its folds and shadows.

The GPU server sends a human-parser label map together with every result. The garment
pixels are moved to the target colour in CIE Lab: lightness keeps the garment's own
shading (folds, seams, shadows), a and b become the target's. Pure CPU, ~0.2-0.5 s.
"""
from __future__ import annotations

import re

import numpy as np
from PIL import Image, ImageFilter

# FASHN human parser label ids (same as gpu_server/enhance.py)
PART_LABELS: dict[str, list[int]] = {
    "upper": [3, 4, 10],  # top, outerwear, ...
    "lower": [5, 6, 7],   # pants, skirt, ...
    "dress": [3, 4, 10, 5, 6, 7],
}
CATEGORY_PART = {"upper_body": "upper", "lower_body": "lower", "dresses": "dress"}
HEX_RE = re.compile(r"^#?([0-9a-fA-F]{6})$")

# Palette offered in the app (name keys are Russian, translated in the app).
PALETTE: list[tuple[str, str]] = [
    ("Чёрный", "#1b1b1d"), ("Белый", "#f1f0ec"), ("Серый", "#8a8c90"), ("Графит", "#45474d"),
    ("Тёмно-синий", "#1f2f55"), ("Синий", "#2f5bb5"), ("Голубой", "#86b4e3"), ("Бирюзовый", "#2a9d9a"),
    ("Зелёный", "#2f7d4f"), ("Хаки", "#76734a"), ("Бежевый", "#cdb391"), ("Коричневый", "#6b4630"),
    ("Бордовый", "#6e1f2e"), ("Красный", "#c0302b"), ("Розовый", "#e8a0b8"), ("Лавандовый", "#a996d6"),
    ("Жёлтый", "#e2bd3c"), ("Оранжевый", "#de7a2c"),
]


def parse_hex(value: str) -> tuple[int, int, int]:
    match = HEX_RE.match((value or "").strip())
    if not match:
        raise ValueError("colour must look like #RRGGBB")
    h = match.group(1)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


# ---------------------------------------------------------------- sRGB <-> Lab (D65)
_M = np.array([[0.4124564, 0.3575761, 0.1804375],
               [0.2126729, 0.7151522, 0.0721750],
               [0.0193339, 0.1191920, 0.9503041]])
_M_INV = np.linalg.inv(_M)
_WHITE = np.array([0.95047, 1.0, 1.08883])


def _to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    xyz = _to_linear(rgb / 255.0) @ _M.T / _WHITE
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def lab_to_rgb(lab: np.ndarray) -> np.ndarray:
    fy = (lab[..., 0] + 16) / 116
    fx = fy + lab[..., 1] / 500
    fz = fy - lab[..., 2] / 200
    f = np.stack([fx, fy, fz], -1)
    xyz = np.where(f**3 > 216 / 24389, f**3, (116 * f - 16) / (24389 / 27)) * _WHITE
    return _to_srgb(xyz @ _M_INV.T) * 255.0


# ---------------------------------------------------------------- main
def garment_mask(seg: np.ndarray, part: str) -> np.ndarray:
    return np.isin(seg, PART_LABELS[part])


def parts_present(seg: np.ndarray, min_share: float = 0.004) -> list[str]:
    total = seg.size
    found = []
    for part in ("upper", "lower"):
        if np.isin(seg, PART_LABELS[part]).sum() / total >= min_share:
            found.append(part)
    return found


def recolor(image: Image.Image, seg: np.ndarray, part: str, target_hex: str) -> Image.Image:
    rgb = np.asarray(image.convert("RGB")).astype(np.float64)
    if seg.shape[:2] != rgb.shape[:2]:
        seg = np.asarray(Image.fromarray(seg.astype(np.uint8)).resize(
            (rgb.shape[1], rgb.shape[0]), Image.Resampling.NEAREST))
    hard = garment_mask(seg, part)
    if hard.sum() < 50:
        raise LookupError("garment not found on the picture")

    # Soft edge: 1-2 px feather so the border does not look cut out.
    radius = max(1.0, min(rgb.shape[:2]) / 900)
    soft = Image.fromarray((hard * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))
    alpha = (np.asarray(soft).astype(np.float64) / 255.0)[..., None]

    ys, xs = np.nonzero(alpha[..., 0] > 0.01)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    region = rgb[y0:y1, x0:x1]
    lab = rgb_to_lab(region)
    target = rgb_to_lab(np.array(parse_hex(target_hex), dtype=np.float64)[None, None, :])[0, 0]

    inside = hard[y0:y1, x0:x1]
    lightness = lab[..., 0]
    garment_l = lightness[inside]
    median = float(np.median(garment_l))
    spread = float(np.percentile(garment_l, 90) - np.percentile(garment_l, 10))
    # Folds of a dark garment span a few L units, of a white one ~20: bring them to a
    # natural amplitude for the new colour (stronger on mid tones, softer on black/white).
    room = min(target[0], 100 - target[0])
    wanted = 10 + 0.18 * room
    gain = float(np.clip(wanted / max(spread, 1.0), 0.35, 2.2))
    new_l = np.clip(target[0] + (lightness - median) * gain, 2, 99)
    # Darker folds lose a little saturation, highlights too - like real fabric.
    chroma = np.clip(1 - np.abs(new_l - target[0]) / 120, 0.55, 1.0)
    new_lab = np.stack([new_l, target[1] * chroma, target[2] * chroma], -1)
    new_rgb = lab_to_rgb(new_lab)

    out = rgb.copy()
    a = alpha[y0:y1, x0:x1]
    out[y0:y1, x0:x1] = new_rgb * a + region * (1 - a)
    return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8))
