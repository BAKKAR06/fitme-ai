"""
FitMe — автоматическая оценка результатов примерки (без эталонных фото).

Для каждого результата считает:
  color_dE      — насколько цвет вещи на результате отличается от цвета на фото вещи
                  (ΔE в пространстве Lab, меньше = лучше; <10 почти незаметно, >25 — другой цвет)
  face_ssim     — насколько сохранено лицо и волосы (0..1, больше = лучше)
  bg_ssim       — насколько сохранён фон (0..1, больше = лучше)
  garment_cover — доля кадра, занятая вещью нужной категории (0 = модель вещь не нарисовала)

Разметку частей тела делает SegFormer (mattmdjaga/segformer_b2_clothes), работает и на CPU.

    python evaluate.py                # оценить всё в results/
    python evaluate.py --device cuda
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent
TEST_DIR = ROOT / "test_set"
RESULTS_DIR = ROOT / "results"

# Классы segformer_b2_clothes
BG, HAIR, FACE = 0, 2, 11
UPPER, SKIRT, PANTS, DRESS = 4, 5, 6, 7
CATEGORY_CLASSES = {"upper_body": [UPPER], "lower_body": [SKIRT, PANTS], "dresses": [DRESS, UPPER, SKIRT]}


# ----------------------------- colour helpers ------------------------------ #
def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """rgb: (..., 3) uint8 -> Lab (D65)."""
    c = rgb.astype(np.float64) / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def garment_pixels_flatlay(img: np.ndarray) -> np.ndarray:
    """Пиксели вещи на фото товара: всё, что заметно отличается от цвета углов (фона)."""
    h, w, _ = img.shape
    s = max(4, min(h, w) // 24)
    corners = np.concatenate([img[:s, :s], img[:s, -s:], img[-s:, :s], img[-s:, -s:]]).reshape(-1, 3)
    bg = np.median(corners, axis=0)
    diff = np.abs(img.astype(int) - bg).max(axis=-1)
    return img[diff > 30]


def median_lab(pixels: np.ndarray) -> np.ndarray | None:
    if len(pixels) < 200:
        return None
    return np.median(rgb_to_lab(pixels.reshape(-1, 3)), axis=0)


def delta_e(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.linalg.norm(a - b))


# ------------------------------ similarity --------------------------------- #
def masked_ssim(a: np.ndarray, b: np.ndarray, mask: np.ndarray) -> float | None:
    if mask.sum() < 400:
        return None
    from skimage.metrics import structural_similarity

    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    ga = np.asarray(Image.fromarray(a[y0:y1, x0:x1]).convert("L"), dtype=np.float64)
    gb = np.asarray(Image.fromarray(b[y0:y1, x0:x1]).convert("L"), dtype=np.float64)
    if min(ga.shape) < 7:
        return None
    _, full = structural_similarity(ga, gb, data_range=255, full=True)
    return float(full[mask[y0:y1, x0:x1]].mean())


# ------------------------------- parsing ----------------------------------- #
class Parser:
    def __init__(self, device: str = "cpu"):
        import torch
        from transformers import AutoModelForSemanticSegmentation, SegformerImageProcessor

        self.torch = torch
        self.device = device
        name = "mattmdjaga/segformer_b2_clothes"
        self.proc = SegformerImageProcessor.from_pretrained(name)
        self.model = AutoModelForSemanticSegmentation.from_pretrained(name).to(device).eval()

    def __call__(self, img: Image.Image) -> np.ndarray:
        inputs = self.proc(images=img, return_tensors="pt").to(self.device)
        with self.torch.no_grad():
            logits = self.model(**inputs).logits
        up = self.torch.nn.functional.interpolate(logits, size=img.size[::-1], mode="bilinear", align_corners=False)
        return up.argmax(dim=1)[0].cpu().numpy()


def load(path: Path, size: tuple[int, int] | None = None) -> Image.Image:
    img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    if size and img.size != size:
        img = img.resize(size, Image.Resampling.LANCZOS)
    return img


def evaluate_one(parser: Parser, person: Path, garment: Path, result: Path, category: str) -> dict:
    src = load(person)
    src.thumbnail((768, 1024))
    out = load(result, src.size)
    a, b = np.asarray(src), np.asarray(out)
    seg_a, seg_b = parser(src), parser(out)

    garment_mask = np.isin(seg_b, CATEGORY_CLASSES[category])
    target = median_lab(garment_pixels_flatlay(np.asarray(load(garment))))
    got = median_lab(b[garment_mask])
    face = np.isin(seg_a, [FACE, HAIR]) & np.isin(seg_b, [FACE, HAIR])
    bg = (seg_a == BG) & (seg_b == BG)

    return {
        "color_dE": round(delta_e(target, got), 1) if target is not None and got is not None else "",
        "face_ssim": _r(masked_ssim(a, b, face)),
        "bg_ssim": _r(masked_ssim(a, b, bg)),
        "garment_cover": round(float(garment_mask.mean()), 3),
    }


def _r(v: float | None) -> str | float:
    return "" if v is None else round(v, 3)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    pairs = list(csv.DictReader((TEST_DIR / "pairs.csv").open(encoding="utf-8-sig")))
    by_id = {f"{Path(r['person']).stem}__{Path(r['garment']).stem}": r for r in pairs}
    parser = Parser(args.device)

    rows = []
    for model_dir in sorted(p for p in RESULTS_DIR.iterdir() if p.is_dir() and p.name != "grids"):
        for res in sorted(model_dir.glob("*.png")):
            pair = by_id.get(res.stem)
            if not pair:
                continue
            try:
                m = evaluate_one(parser, TEST_DIR / pair["person"], TEST_DIR / pair["garment"], res, pair["category"])
            except Exception as exc:  # одна битая картинка не должна ронять всю оценку
                print(f"skip {model_dir.name}/{res.name}: {exc}")
                continue
            rows.append({"model": model_dir.name, "pair": res.stem, **m})
            print(model_dir.name, res.stem, m)

    if not rows:
        print("Нет результатов для оценки.")
        return
    out = RESULTS_DIR / "metrics.csv"
    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    print("\nСредние по моделям (color_dE ↓, face_ssim ↑, bg_ssim ↑):")
    summary = []
    for model in sorted({r["model"] for r in rows}):
        sel = [r for r in rows if r["model"] == model]

        def avg(key: str) -> str:
            vals = [float(r[key]) for r in sel if r[key] != ""]
            return f"{np.mean(vals):.3f}" if vals else "-"

        summary.append({"model": model, "n": len(sel), "color_dE": avg("color_dE"), "face_ssim": avg("face_ssim"), "bg_ssim": avg("bg_ssim"), "garment_cover": avg("garment_cover")})
        print(f"  {model:22s} n={len(sel):3d}  dE={summary[-1]['color_dE']:>7}  face={summary[-1]['face_ssim']:>6}  bg={summary[-1]['bg_ssim']:>6}")
    with (RESULTS_DIR / "summary.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0]))
        w.writeheader()
        w.writerows(summary)
    print(f"\nПодробно: {out}\nИтог: {RESULTS_DIR / 'summary.csv'}")


if __name__ == "__main__":
    main()
