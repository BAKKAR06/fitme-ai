"""FitMe v4 lab, part 2: checks two fixes found in part 1 (still experiment-only).

1. "nocolor": v3 shifts the colours of the whole generated body by the face colour
   difference (match_colors). On a white shirt that gave a lilac tint. Here the same
   v3 pipeline is reproduced locally from the raw FASHN output, with and without it.
2. "zoom2": the zoom pass pasted a dilated union mask and touched skin/background at
   sleeve edges. zoom2 pastes only the inside of the garment in the new generation.

Uses the running GPU server only for raw generations (enhance=false); crop, upscale and
paste-back run here (Real-ESRGAN on the GPU, ~1 GB, parser + DINOv2 on the CPU).
    gpu_server\\.venv\\Scripts\\python.exe experiments\\v4_lab2.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "gpu_server"))
sys.path.insert(0, str(ROOT / "experiments"))

import enhance  # noqa: E402  (gpu_server/enhance.py - same code the app uses)
import v4_lab as lab  # noqa: E402  (parser, metrics, server client)

UPSCALER = enhance.load_upscaler(ROOT / "gpu_server" / "weights", device="cuda")
lab.log("lab2: upscaler", "on" if UPSCALER else "OFF")


def aparse(rgb: np.ndarray) -> np.ndarray:
    """Same call as gpu_server/fashn_server.parse: numpy RGB in, label map of the same size out."""
    seg = np.asarray(lab.PARSER.predict(np.ascontiguousarray(rgb))).astype(np.uint8)
    if seg.shape[:2] != rgb.shape[:2]:
        seg = cv2.resize(seg, (rgb.shape[1], rgb.shape[0]), interpolation=cv2.INTER_NEAREST)
    return seg


def v3_local(person: Image.Image, raw: Image.Image, box, color_match: bool) -> Image.Image:
    original = enhance.match_colors
    if not color_match:
        enhance.match_colors = lambda result, orig, region: result
    try:
        return enhance.finish_result(person, box, raw, aparse, UPSCALER)
    finally:
        enhance.match_colors = original


def zoom2(result: Image.Image, garment: bytes, cat: str, guidance=1.5, seed=42):
    seg = lab.parse(result)
    ids = lab.GARMENT_IDS[cat]
    box, person_box = lab.bbox(np.isin(seg, ids)), lab.bbox(seg != 0)
    if box is None or person_box is None:
        return None, 0.0
    W, H = result.size
    x0, y0, x1, y1 = box
    mx, my = 0.12 * (x1 - x0), 0.12 * (y1 - y0)
    x0, y0, x1, y1 = x0 - mx, y0 - my, x1 + mx, y1 + my
    w, h = x1 - x0, y1 - y0
    if w / h > 2 / 3:
        h = w * 1.5
    else:
        w = h * 2 / 3
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    w, h = min(w, W), min(h, H)
    left, top = int(min(max(cx - w / 2, 0), W - w)), int(min(max(cy - h / 2, 0), H - h))
    crop_box = (left, top, left + int(w), top + int(h))
    pb = person_box
    if (crop_box[2] - crop_box[0]) * (crop_box[3] - crop_box[1]) > 0.6 * (pb[2] - pb[0]) * (pb[3] - pb[1]):
        return None, 0.0
    crop = result.crop(crop_box)
    out, secs = lab.tryon(lab.to_jpeg(crop), garment, cat, guidance, seed, enhance=True)
    if out.size != crop.size:
        out = out.resize(crop.size, Image.Resampling.LANCZOS)
    # only the inside of the garment of BOTH images: never touches skin or background
    m = np.isin(lab.parse(out), ids) & np.isin(lab.parse(crop), ids)
    e = max(2, int(0.006 * crop.height))
    m = cv2.erode(m.astype(np.uint8), np.ones((2 * e + 1, 2 * e + 1), np.uint8))
    f = max(3, int(0.01 * crop.height)) * 2 + 1
    alpha = cv2.GaussianBlur(m.astype(np.float32), (f, f), 0)[..., None]
    merged = np.asarray(out).astype(np.float32) * alpha + np.asarray(crop).astype(np.float32) * (1 - alpha)
    final = result.copy()
    final.paste(Image.fromarray(np.clip(merged, 0, 255).astype(np.uint8)), crop_box[:2])
    return final, secs


def main():
    OUT = lab.OUT
    catalog = {i["item_id"]: i for i in json.loads((ROOT / "backend/data/catalog.json").read_text(encoding="utf-8"))}
    rfile = OUT / "results.json"
    results = json.loads(rfile.read_text(encoding="utf-8"))

    def save():
        rfile.write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")

    for idx, (pfile, gid, cat) in enumerate(lab.PAIRS):
        pid = f"p{idx + 1}_{cat.split('_')[0]}"
        if pid not in results or all(k in results[pid] for k in ("v3local", "nocolor", "zoom2")):
            continue
        person = ImageOps.exif_transpose(Image.open(ROOT / "backend/uploads" / pfile)).convert("RGB")
        person.thumbnail((2400, 2400))
        garment_bytes = (ROOT / "backend/catalog" / catalog[gid]["file_name"]).read_bytes()
        ref = lab.embed(Image.open(OUT / pid / "0_garment_ref.jpg"))
        seg_p = lab.parse(person)

        def measure(name, img, secs):
            seg_r, mask = lab.garment_region(img, cat)
            row = {"secs": secs, "size": list(img.size),
                   "fidelity": round(lab.fidelity(ref, img, mask), 4),
                   "sharpness": round(lab.sharpness(img, mask), 1),
                   "preservation": round(lab.preservation(person, img, seg_p, seg_r), 4)}
            img.save(OUT / pid / f"{name}.jpg", quality=92)
            results[pid][name] = row
            save()
            lab.log(pid, name, row)

        if "nocolor" not in results[pid]:
          try:
            crop, box = enhance.crop_to_person(person, aparse)
            raw, secs = lab.tryon(lab.to_jpeg(crop), garment_bytes, cat, 1.5, 42, enhance=False)
            measure("v3local", v3_local(person, raw, box, True), secs)
            measure("nocolor", v3_local(person, raw, box, False), secs)
          except Exception as exc:
            lab.log(pid, "lab2 v3local/nocolor FAILED", type(exc).__name__, str(exc)[:300])
        if "zoom2" in results[pid] or results[pid].get("_zoom2_skipped"):
            continue
        try:
            base = Image.open(OUT / pid / "v3.jpg").convert("RGB")
            img, secs = zoom2(base, garment_bytes, cat)
            if img is not None:
                measure("zoom2", img, secs)
            else:
                results[pid]["_zoom2_skipped"] = True
                save()
                lab.log(pid, "zoom2 skipped (garment zone is almost the whole person)")
        except Exception as exc:
            lab.log(pid, "lab2 zoom2 FAILED", type(exc).__name__, str(exc)[:300])

    variants = ["v2", "v3", "v3local", "nocolor", "g2.0", "g2.5", "best4", "prep", "zoom", "zoom2", "v4"]
    lines = ["| вариант | n | сходство вещи ↑ | детализация ↑ | сохранность лица/фона ↑ | время, с |", "|---|---|---|---|---|---|"]
    summary = {}
    for v in variants:
        rows = [r[v] for r in results.values() if isinstance(r, dict) and v in r]
        if not rows:
            continue
        s = {k: float(np.mean([x[k] for x in rows])) for k in ("fidelity", "sharpness", "preservation", "secs")}
        summary[v] = dict(s, n=len(rows))
        lines.append(f"| {v} | {len(rows)} | {s['fidelity']:.3f} | {s['sharpness']:.0f} | {s['preservation']:.3f} | {s['secs']:.0f} |")
    (OUT / "summary2.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    lab.log("\n" + "\n".join(lines))
    lab.log("LAB2 DONE")


if __name__ == "__main__":
    main()
