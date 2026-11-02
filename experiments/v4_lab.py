"""FitMe v4 quality lab: tries the planned improvements WITHOUT changing the running app.

It only sends jobs to the GPU server that is already running (http://127.0.0.1:7860)
and does all extra work (garment preparation, zoom pass, best-of-N, metrics) here.
Results: test_output/v4_lab/ (git-ignored, contains your photos).

    gpu_server\\.venv\\Scripts\\python.exe experiments\\v4_lab.py

Variants per test pair (person + garment):
  v2        plain FASHN output (no enhance)                  - reference
  v3        current app: crop + Real-ESRGAN + paste-back     - baseline
  g2.0/g2.5 v3 with stronger garment guidance
  s7/s1234/s99  v3 with other seeds -> best-of-4 (picked by garment similarity)
  prep      v3 with the garment photo cut out + centred + enlarged
  zoom      v3 + second pass on the garment zone (more pixels for prints/logos)
  v4        everything together: prep + best guidance + best-of-2 + zoom

Metrics (no ground truth needed):
  fidelity      DINOv2 similarity between the garment in the result and the garment photo (higher = more faithful)
  sharpness     Laplacian variance inside the garment (higher = more fine detail)
  preservation  SSIM of face + background against the original photo (1.0 = untouched)
"""
from __future__ import annotations

import io
import json
import sys
import time
import urllib.request
import uuid
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "test_output" / "v4_lab"
OUT.mkdir(parents=True, exist_ok=True)
SERVER = "http://127.0.0.1:7860"
STEPS = 30
CATEGORY = {"upper_body": "tops", "lower_body": "bottoms", "dresses": "one-pieces"}
GARMENT_IDS = {"upper_body": [3, 4, 10], "lower_body": [5, 6, 7], "dresses": [3, 4, 10, 5, 6, 7]}
BODY_IDS = [1, 2, 12, 13, 14, 15, 16]
KEEP_IDS = [0, 1, 2, 11]  # background, face, hair, glasses -> must stay as in the original

# person file (backend/uploads) , garment catalog id , category
PAIRS = [
    ("8eed06fa53_person.png", "bb6b0420e4", "upper_body"),  # you + printed T-shirt (text, face print)
    ("8eed06fa53_person.png", "2727af8974", "upper_body"),  # you + anorak
    ("4ec4d8611d_person.jpg", "ea87e12f7c", "upper_body"),  # jacket with stripes
    ("3c5e53ddf7_person.jpg", "a433e83119", "upper_body"),  # white shirt
    ("b9357619b9_person.png", "bb6b0420e4", "upper_body"),  # studio photo + printed T-shirt
    ("2a2f2e8e68_person.jpg", "3d9d229f87", "upper_body"),  # sweatshirt
    ("8eed06fa53_person.png", "38f0eca959", "lower_body"),  # you + trousers
    ("58586e2ad0_person.png", "3bb73cc880", "lower_body"),  # shorts
]

LOG = OUT / "lab_log.txt"


def log(*a):
    line = time.strftime("%H:%M:%S ") + " ".join(str(x) for x in a)
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


# --------------------------------------------------------------------------- models (CPU)
torch.set_num_threads(max(2, (torch.get_num_threads() or 4)))
from fashn_human_parser import FashnHumanParser  # noqa: E402
from transformers import AutoImageProcessor, AutoModel  # noqa: E402

log("loading human parser + DINOv2 on CPU (GPU stays free for the server)...")
PARSER = FashnHumanParser(device="cpu")
DINO_PROC = AutoImageProcessor.from_pretrained("facebook/dinov2-small")
DINO = AutoModel.from_pretrained("facebook/dinov2-small").eval()


def parse(img: Image.Image, side: int = 768) -> np.ndarray:
    small = img.convert("RGB").copy()
    small.thumbnail((side, side), Image.Resampling.BILINEAR)
    seg = np.asarray(PARSER.predict(np.asarray(small))).astype(np.uint8)
    if seg.shape[:2] != (small.height, small.width):
        seg = cv2.resize(seg, (small.width, small.height), interpolation=cv2.INTER_NEAREST)
    return cv2.resize(seg, img.size, interpolation=cv2.INTER_NEAREST)


@torch.inference_mode()
def embed(img: Image.Image) -> np.ndarray:
    img = ImageOps.pad(img.convert("RGB"), (448, 448), color="white")  # keep the whole garment (no centre crop)
    inputs = DINO_PROC(images=img, return_tensors="pt", do_center_crop=False,
                       size={"height": 224, "width": 224}, do_resize=True)
    out = DINO(**inputs).last_hidden_state
    v = torch.cat([out[:, 0], out[:, 1:].mean(1)], dim=1)[0].numpy()
    return v / (np.linalg.norm(v) + 1e-8)


def bbox(mask: np.ndarray):
    ys, xs = np.nonzero(mask)
    if len(xs) < 200:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def on_white(img: Image.Image, mask: np.ndarray, box) -> Image.Image:
    arr = np.asarray(img.convert("RGB")).copy()
    arr[~mask] = 255
    return Image.fromarray(arr).crop(box)


# --------------------------------------------------------------------------- garment
def garment_cutout(g: Image.Image, cat: str) -> tuple[Image.Image, str]:
    """Garment alone on white, cropped to its edges. Returns (image, 'model'|'flat-lay')."""
    seg = parse(g)
    body_share = float(np.isin(seg, BODY_IDS).mean())
    if body_share > 0.015:
        mask = np.isin(seg, GARMENT_IDS[cat])
        kind = "model"
    else:
        arr = np.asarray(g.convert("RGB")).astype(int)
        h, w = arr.shape[:2]
        s = max(6, min(h, w) // 25)
        corners = np.concatenate([arr[:s, :s].reshape(-1, 3), arr[:s, -s:].reshape(-1, 3),
                                  arr[-s:, :s].reshape(-1, 3), arr[-s:, -s:].reshape(-1, 3)])
        bg = np.median(corners, axis=0)
        mask = np.abs(arr - bg).max(axis=2) > 28
        mask = cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8)).astype(bool)
        kind = "flat-lay"
    box = bbox(mask)
    if box is None:
        return g.convert("RGB"), kind
    return on_white(g, mask, box), kind


def prepare_garment(g: Image.Image, cat: str) -> bytes:
    """v4 garment preparation: cut out, centre on white with margin (3:4), enlarge small photos."""
    cut, _ = garment_cutout(g, cat)
    w, h = cut.size
    target_h = max(h, int(w / 0.75))
    canvas_h = int(target_h * 1.08)
    canvas_w = int(canvas_h * 0.75)
    canvas = Image.new("RGB", (canvas_w, canvas_h), "white")
    canvas.paste(cut, ((canvas_w - w) // 2, (canvas_h - h) // 2))
    if canvas_h < 1024:
        canvas = canvas.resize((int(1024 * 0.75), 1024), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    canvas.save(buf, "JPEG", quality=95)
    return buf.getvalue()


# --------------------------------------------------------------------------- metrics
def garment_region(result: Image.Image, cat: str):
    seg = parse(result)
    mask = np.isin(seg, GARMENT_IDS[cat])
    return seg, mask


def fidelity(ref_emb: np.ndarray, result: Image.Image, mask: np.ndarray) -> float:
    box = bbox(mask)
    if box is None:
        return 0.0
    return float(np.dot(ref_emb, embed(on_white(result, mask, box))))


def sharpness(result: Image.Image, mask: np.ndarray) -> float:
    box = bbox(mask)
    if box is None:
        return 0.0
    gray = cv2.cvtColor(np.asarray(result.convert("RGB")), cv2.COLOR_RGB2GRAY).astype(np.float32)
    crop, m = gray[box[1]:box[3], box[0]:box[2]], mask[box[1]:box[3], box[0]:box[2]]
    scale = 700 / crop.shape[0]  # compare at the same garment height
    crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    m = cv2.resize(m.astype(np.uint8), (crop.shape[1], crop.shape[0]), interpolation=cv2.INTER_NEAREST).astype(bool)
    m = cv2.erode(m.astype(np.uint8), np.ones((7, 7), np.uint8)).astype(bool)
    lap = cv2.Laplacian(crop, cv2.CV_32F)
    return float(lap[m].var()) if m.sum() > 100 else 0.0


def preservation(person: Image.Image, result: Image.Image, seg_person: np.ndarray, seg_result: np.ndarray) -> float:
    p = person.convert("RGB").resize(result.size, Image.Resampling.LANCZOS)
    sp = cv2.resize(seg_person, result.size, interpolation=cv2.INTER_NEAREST)
    keep = np.isin(sp, KEEP_IDS) & np.isin(seg_result, KEEP_IDS)
    keep = cv2.erode(keep.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool)
    if keep.sum() < 500:
        return 0.0
    a = cv2.cvtColor(np.asarray(p), cv2.COLOR_RGB2GRAY).astype(np.float32)
    b = cv2.cvtColor(np.asarray(result.convert("RGB")), cv2.COLOR_RGB2GRAY).astype(np.float32)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    mu1, mu2 = cv2.GaussianBlur(a, (11, 11), 1.5), cv2.GaussianBlur(b, (11, 11), 1.5)
    s1 = cv2.GaussianBlur(a * a, (11, 11), 1.5) - mu1 ** 2
    s2 = cv2.GaussianBlur(b * b, (11, 11), 1.5) - mu2 ** 2
    s12 = cv2.GaussianBlur(a * b, (11, 11), 1.5) - mu1 * mu2
    ssim = ((2 * mu1 * mu2 + c1) * (2 * s12 + c2)) / ((mu1 ** 2 + mu2 ** 2 + c1) * (s1 + s2 + c2))
    return float(ssim[keep].mean())


# --------------------------------------------------------------------------- GPU server
def http_get(url, timeout=60):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def to_jpeg(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "JPEG", quality=95)
    return buf.getvalue()


def tryon(person: bytes, garment: bytes, cat: str, guidance=1.5, seed=42, enhance=True):
    boundary = uuid.uuid4().hex
    fields = {"category": CATEGORY[cat], "garment_photo_type": "auto", "num_timesteps": STEPS,
              "guidance_scale": guidance, "seed": seed, "segmentation_free": "true",
              "enhance": "true" if enhance else "false"}
    body = b""
    for k, v in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    for k, data in (("person_photo", person), ("garment_photo", garment)):
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{k}.jpg"\r\n'
                 "Content-Type: image/jpeg\r\n\r\n").encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    t0 = time.time()
    req = urllib.request.Request(SERVER + "/jobs", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        jid = json.loads(r.read())["job_id"]
    while True:
        st = json.loads(http_get(f"{SERVER}/jobs/{jid}"))
        if st["status"] in ("completed", "failed"):
            break
        time.sleep(0.7)
    if st["status"] == "failed":
        raise RuntimeError(st.get("error"))
    img = Image.open(io.BytesIO(http_get(f"{SERVER}/jobs/{jid}/result"))).convert("RGB")
    return img, round(time.time() - t0, 1)


def zoom_pass(result: Image.Image, garment: bytes, cat: str, guidance: float, seed: int):
    """Second pass: regenerate only the garment zone, bigger, and paste it back."""
    seg = parse(result)
    mask = np.isin(seg, GARMENT_IDS[cat])
    person_box = bbox(seg != 0)
    box = bbox(mask)
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
    left = int(min(max(cx - w / 2, 0), W - w))
    top = int(min(max(cy - h / 2, 0), H - h))
    crop_box = (left, top, left + int(w), top + int(h))
    pb = person_box
    if (crop_box[2] - crop_box[0]) * (crop_box[3] - crop_box[1]) > 0.6 * (pb[2] - pb[0]) * (pb[3] - pb[1]):
        return None, 0.0  # the zone is almost the whole person - nothing to gain
    crop = result.crop(crop_box)
    out, secs = tryon(to_jpeg(crop), garment, cat, guidance, seed, enhance=True)
    if out.size != crop.size:
        out = out.resize(crop.size, Image.Resampling.LANCZOS)
    m = np.isin(parse(out), GARMENT_IDS[cat]) | np.isin(parse(crop), GARMENT_IDS[cat])
    g = max(3, int(0.015 * crop.height))
    m = cv2.dilate(m.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * g + 1, 2 * g + 1)))
    f = max(3, int(0.012 * crop.height)) * 2 + 1
    alpha = cv2.GaussianBlur(m.astype(np.float32), (f, f), 0)[..., None]
    merged = np.asarray(out).astype(np.float32) * alpha + np.asarray(crop).astype(np.float32) * (1 - alpha)
    final = result.copy()
    final.paste(Image.fromarray(np.clip(merged, 0, 255).astype(np.uint8)), crop_box[:2])
    return final, secs


# --------------------------------------------------------------------------- main
def main():
    catalog = {i["item_id"]: i for i in json.loads((ROOT / "backend/data/catalog.json").read_text(encoding="utf-8"))}
    results_file = OUT / "results.json"
    results = json.loads(results_file.read_text(encoding="utf-8")) if results_file.exists() else {}

    def save():
        results_file.write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")

    def measure(pid, name, img, secs, ctx):
        seg_r, mask = garment_region(img, ctx["cat"])
        row = {"secs": secs, "size": list(img.size),
               "fidelity": round(fidelity(ctx["ref"], img, mask), 4),
               "sharpness": round(sharpness(img, mask), 1),
               "preservation": round(preservation(ctx["person"], img, ctx["seg_p"], seg_r), 4)}
        img.save(OUT / pid / f"{name}.jpg", quality=92)
        results[pid][name] = row
        save()
        log(pid, name, row)
        return row

    pair_ctx = {}
    for idx, (pfile, gid, cat) in enumerate(PAIRS):
        pid = f"p{idx + 1}_{cat.split('_')[0]}"
        (OUT / pid).mkdir(exist_ok=True)
        results.setdefault(pid, {})
        person_path = ROOT / "backend/uploads" / pfile
        garment_path = ROOT / "backend/catalog" / catalog[gid]["file_name"]
        if not person_path.exists() or not garment_path.exists():
            log(pid, "skipped: file missing", person_path.name, garment_path.name)
            continue
        person = ImageOps.exif_transpose(Image.open(person_path)).convert("RGB")
        garment = ImageOps.exif_transpose(Image.open(garment_path)).convert("RGB")
        person.thumbnail((2400, 2400))
        ref_img, kind = garment_cutout(garment, cat)
        ref_img.save(OUT / pid / "0_garment_ref.jpg", quality=92)
        person.save(OUT / pid / "0_person.jpg", quality=92)
        ctx = {"cat": cat, "person": person, "seg_p": parse(person), "ref": embed(ref_img),
               "p_bytes": to_jpeg(person), "g_bytes": garment_path.read_bytes(), "g_prep": prepare_garment(garment, cat)}
        pair_ctx[pid] = ctx
        results[pid]["_info"] = {"person": pfile, "garment": catalog[gid]["name"][:80], "category": cat, "garment_photo": kind}
        log("====", pid, results[pid]["_info"])

        def run(name, fn):
            if name in results[pid]:
                return
            try:
                img, secs = fn()
                if img is not None:
                    measure(pid, name, img, secs, ctx)
            except Exception as exc:
                log(pid, name, "FAILED", type(exc).__name__, str(exc)[:300])

        run("v2", lambda: tryon(ctx["p_bytes"], ctx["g_bytes"], cat, 1.5, 42, enhance=False))
        run("v3", lambda: tryon(ctx["p_bytes"], ctx["g_bytes"], cat, 1.5, 42))
        run("g2.0", lambda: tryon(ctx["p_bytes"], ctx["g_bytes"], cat, 2.0, 42))
        run("g2.5", lambda: tryon(ctx["p_bytes"], ctx["g_bytes"], cat, 2.5, 42))
        for s in (7, 1234, 99):
            run(f"s{s}", lambda s=s: tryon(ctx["p_bytes"], ctx["g_bytes"], cat, 1.5, s))
        run("prep", lambda: tryon(ctx["p_bytes"], ctx["g_prep"], cat, 1.5, 42))
        if (OUT / pid / "v3.jpg").exists():
            run("zoom", lambda: zoom_pass(Image.open(OUT / pid / "v3.jpg").convert("RGB"), ctx["g_bytes"], cat, 1.5, 42))

    # ---- choose guidance by average fidelity, then the full v4 pipeline
    g_scores = {}
    for g in ("v3", "g2.0", "g2.5"):
        vals = [r[g]["fidelity"] for r in results.values() if g in r]
        g_scores[g] = float(np.mean(vals)) if vals else 0.0
    best_g = {"v3": 1.5, "g2.0": 2.0, "g2.5": 2.5}[max(g_scores, key=g_scores.get)]
    log("guidance scores", g_scores, "-> v4 uses", best_g)

    for pid, ctx in pair_ctx.items():
        if "v4" in results[pid]:
            continue
        try:
            t0 = time.time()
            cands = []
            for s in (42, 7):
                img, _ = tryon(ctx["p_bytes"], ctx["g_prep"], ctx["cat"], best_g, s)
                _, mask = garment_region(img, ctx["cat"])
                cands.append((fidelity(ctx["ref"], img, mask), s, img))
            score, seed, best = max(cands, key=lambda c: c[0])
            zoomed, _ = zoom_pass(best, ctx["g_prep"], ctx["cat"], best_g, seed)
            measure(pid, "v4", zoomed or best, round(time.time() - t0, 1), ctx)
            results[pid]["v4"]["seed"], results[pid]["v4"]["guidance"] = seed, best_g
            results[pid]["v4"]["zoomed"] = zoomed is not None
            save()
        except Exception as exc:
            log(pid, "v4 FAILED", type(exc).__name__, str(exc)[:300])

    # ---- best-of-4 summary row (already generated images, no extra GPU)
    for pid, r in results.items():
        seeds = [k for k in ("v3", "s7", "s1234", "s99") if k in r]
        if seeds:
            best = max(seeds, key=lambda k: r[k]["fidelity"])
            r["best4"] = dict(r[best], picked=best, secs=round(sum(r[k]["secs"] for k in seeds), 1))
    save()

    # ---- table + grids
    variants = ["v2", "v3", "g2.0", "g2.5", "best4", "prep", "zoom", "v4"]
    lines = ["| вариант | сходство вещи ↑ | детализация ↑ | сохранность лица/фона ↑ | время, с |", "|---|---|---|---|---|"]
    summary = {}
    for v in variants:
        rows = [r[v] for r in results.values() if v in r]
        if not rows:
            continue
        summary[v] = {k: float(np.mean([x[k] for x in rows])) for k in ("fidelity", "sharpness", "preservation", "secs")}
        summary[v]["n"] = len(rows)
        s = summary[v]
        lines.append(f"| {v} | {s['fidelity']:.3f} | {s['sharpness']:.0f} | {s['preservation']:.3f} | {s['secs']:.0f} |")
    (OUT / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (OUT / "summary.json").write_text(json.dumps({"guidance": g_scores, "variants": summary}, indent=1), encoding="utf-8")
    log("\n" + "\n".join(lines))

    try:
        font = ImageFont.truetype("arial.ttf", 22)
    except Exception:
        font = ImageFont.load_default()
    for pid, r in results.items():
        tiles = [("фото", OUT / pid / "0_person.jpg"), ("вещь", OUT / pid / "0_garment_ref.jpg")]
        tiles += [(v, OUT / pid / f"{r[v].get('picked', v) if v == 'best4' else v}.jpg") for v in ("v2", "v3", "best4", "prep", "zoom", "v4") if v in r]
        cols, H = [], 900
        for title, path in tiles:
            if not path.exists():
                continue
            img = Image.open(path).convert("RGB")
            w = int(img.width * H / img.height)
            col = Image.new("RGB", (w, H + 40), "white")
            col.paste(img.resize((w, H), Image.Resampling.LANCZOS), (0, 40))
            sub = r.get(title, {})
            label = title if not sub else f"{title}  F={sub['fidelity']:.3f} S={sub['sharpness']:.0f}"
            ImageDraw.Draw(col).text((6, 8), label, fill="black", font=font)
            cols.append(col)
        if cols:
            sheet = Image.new("RGB", (sum(c.width for c in cols) + 10 * len(cols), H + 40), "white")
            x = 0
            for c in cols:
                sheet.paste(c, (x, 0))
                x += c.width + 10
            sheet.save(OUT / f"grid_{pid}.jpg", quality=88)
    log("LAB DONE")


if __name__ == "__main__":
    main()
