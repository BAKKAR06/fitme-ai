"""FitMe: compare all 7 free try-on options on YOUR photo and one garment.

    backend\\.venv\\Scripts\\python.exe benchmark\\bench_avatar.py [person.jpg] [garment.jpg]

Without arguments: person = newest photo sent from the phone (backend/uploads),
garment = first "upper_body" item of your catalog (backend/data/catalog.json).
Results go to test_output/avatar_bench/ (git-ignored: it contains your photo).

Options compared:
  1 FASHN VTON 1.5 local (v2, plain)       local RTX GPU, http://127.0.0.1:7860
  2 FASHN VTON 1.5 local (v3, enhanced)    local RTX GPU
  3 FASHN VTON 1.5 cloud                   Hugging Face ZeroGPU
  4 Leffa                                  Hugging Face ZeroGPU
  5 FitDiT                                 Hugging Face ZeroGPU
  6 IDM-VTON                               Hugging Face ZeroGPU
  7 OOTDiffusion                           Hugging Face ZeroGPU
The Hugging Face token (more free GPU minutes) is read from backend/data/hf_token.txt.
"""
from __future__ import annotations

import io
import json
import sys
import time
import traceback
import urllib.request
import uuid
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))
from app.hf_space import QuotaExceeded, space_try_on  # noqa: E402

OUT = ROOT / "test_output" / "avatar_bench"
OUT.mkdir(parents=True, exist_ok=True)
GPU = "http://127.0.0.1:7860"
DEMO_CLOTH = "https://huggingface.co/spaces/yisol/IDM-VTON/resolve/main/example/cloth/04469_00.jpg"
STEPS = 30
SEED = 42


def log(*args):
    print(*args, flush=True)


def get(url, timeout=60):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def post_multipart(url, fields, files):
    boundary = uuid.uuid4().hex
    body = b""
    for k, v in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    for k, (name, data) in files.items():
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{name}"\r\n'
                 f"Content-Type: image/jpeg\r\n\r\n").encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def pick_inputs() -> tuple[Path, Path, str]:
    if len(sys.argv) >= 3:
        return Path(sys.argv[1]), Path(sys.argv[2]), "из аргументов"
    uploads = sorted((ROOT / "backend" / "uploads").glob("*_person.*"), key=lambda p: p.stat().st_mtime)
    if not uploads:
        sys.exit("Нет фото человека: сначала сделайте одну примерку с телефона или передайте путь к фото.")
    person = uploads[-1]
    catalog = ROOT / "backend" / "data" / "catalog.json"
    garment, name = None, "демо-футболка"
    if catalog.exists():
        for item in json.loads(catalog.read_text(encoding="utf-8")):
            path = ROOT / "backend" / "catalog" / str(item.get("file_name", ""))
            if item.get("category") == "upper_body" and path.exists():
                garment, name = path, str(item.get("name") or "вещь из каталога")
                break
    if garment is None:
        garment = OUT / "demo_cloth.jpg"
        garment.write_bytes(get(DEMO_CLOTH))
    return person, garment, name


def run_local(person: bytes, garment: bytes, enhance: bool) -> tuple[Image.Image, dict]:
    job = post_multipart(GPU + "/jobs",
                         {"category": "tops", "garment_photo_type": "auto", "num_timesteps": STEPS,
                          "guidance_scale": 1.5, "seed": SEED, "segmentation_free": "true",
                          "enhance": "true" if enhance else "false"},
                         {"person_photo": ("p.jpg", person), "garment_photo": ("g.jpg", garment)})
    jid = job["job_id"]
    while True:
        st = json.loads(get(f"{GPU}/jobs/{jid}"))
        if st["status"] in ("completed", "failed"):
            break
        time.sleep(0.5)
    if st["status"] == "failed":
        raise RuntimeError(st.get("error"))
    return Image.open(io.BytesIO(get(f"{GPU}/jobs/{jid}/result"))).convert("RGB"), st


def main():
    person_path, garment_path, garment_name = pick_inputs()
    token_file = ROOT / "backend" / "data" / "hf_token.txt"
    token = token_file.read_text(encoding="utf-8").strip() if token_file.exists() else None
    log(f"person: {person_path.name}; garment: {garment_name}; HF token: {'yes' if token else 'NO (2 min/day)'}")
    person_bytes, garment_bytes = person_path.read_bytes(), garment_path.read_bytes()
    Image.open(io.BytesIO(person_bytes)).convert("RGB").save(OUT / "0_person.jpg", quality=92)
    Image.open(io.BytesIO(garment_bytes)).convert("RGB").save(OUT / "0_garment.jpg", quality=92)

    results = []
    photo_type = "auto"

    def record(key, title, where, fn):
        t0 = time.time()
        row = {"key": key, "title": title, "where": where}
        try:
            img, extra = fn()
            row.update(ok=True, seconds=round(time.time() - t0, 1), size=list(img.size), **extra)
            img.save(OUT / f"{key}.jpg", quality=93)
        except QuotaExceeded as exc:
            row.update(ok=False, seconds=round(time.time() - t0, 1), error=f"квота Hugging Face: {str(exc)[:200]}")
        except Exception as exc:  # keep going with the other models
            row.update(ok=False, seconds=round(time.time() - t0, 1), error=f"{type(exc).__name__}: {str(exc)[:300]}")
            traceback.print_exc()
        log(json.dumps(row, ensure_ascii=False))
        results.append(row)
        (OUT / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    def local(enhance):
        nonlocal photo_type
        img, st = run_local(person_bytes, garment_bytes, enhance)
        photo_type = st.get("garment_photo_type") or photo_type
        return img, {"gpu_seconds": st.get("seconds"), "peak_vram_gb": st.get("peak_vram_gb"),
                     "garment_photo_type": st.get("garment_photo_type")}

    def cloud(model_id):
        def fn():
            png = space_try_on(model_id, token, person_path, garment_path, "upper_body", STEPS, SEED, photo_type)
            return Image.open(io.BytesIO(png)).convert("RGB"), {}
        return fn

    record("1_fashn_local_v2", "FASHN 1.5 (ноутбук, v2)", "RTX 4060", lambda: local(False))
    record("2_fashn_local_v3", "FASHN 1.5 (ноутбук, v3)", "RTX 4060", lambda: local(True))
    for key, model_id, title in [
        ("3_fashn_cloud", "fashn_cloud", "FASHN 1.5 (облако)"),
        ("4_ootd", "ootd", "OOTDiffusion"),
        ("5_idm", "idm", "IDM-VTON"),
        ("6_leffa", "leffa", "Leffa"),
        ("7_fitdit", "fitdit", "FitDiT"),
    ]:
        record(key, title, "HF ZeroGPU", cloud(model_id))

    # Grid: full images + zoom on the chest/face area.
    H = 900
    try:
        font = ImageFont.truetype("arial.ttf", 22)
    except Exception:
        font = ImageFont.load_default()
    tiles = [("Исходное фото", Image.open(OUT / "0_person.jpg"), "")]
    tiles.append(("Вещь", ImageOps.pad(Image.open(OUT / "0_garment.jpg"), (600, 900), color="white"), garment_name[:28]))
    for r in results:
        if r["ok"]:
            tiles.append((r["title"], Image.open(OUT / f"{r['key']}.jpg"), f"{r['seconds']} с, {r['size'][0]}x{r['size'][1]}"))
        else:
            ph = Image.new("RGB", (600, 900), (235, 235, 235))
            ImageDraw.Draw(ph).text((20, 420), "не удалось:\n" + r["error"][:120], fill="black", font=font)
            tiles.append((r["title"], ph, "ошибка"))
    cols = []
    for title, img, sub in tiles:
        img = img.convert("RGB")
        w = int(img.width * H / img.height)
        full = img.resize((w, H), Image.Resampling.LANCZOS)
        zoom = img.crop((int(img.width * .2), int(img.height * .08), int(img.width * .8), int(img.height * .45)))
        zoom = zoom.resize((w, int(zoom.height * w / zoom.width)), Image.Resampling.LANCZOS)
        col = Image.new("RGB", (w, 70 + H + zoom.height), "white")
        d = ImageDraw.Draw(col)
        d.text((8, 6), title, fill="black", font=font)
        d.text((8, 36), sub, fill=(90, 90, 90), font=font)
        col.paste(full, (0, 70))
        col.paste(zoom, (0, 70 + H))
        cols.append(col)
    sheet = Image.new("RGB", (sum(c.width for c in cols) + 12 * (len(cols) - 1), max(c.height for c in cols)), "white")
    x = 0
    for c in cols:
        sheet.paste(c, (x, 0))
        x += c.width + 12
    sheet.save(OUT / "grid.jpg", quality=88)
    log("saved test_output/avatar_bench/grid.jpg")
    log("BENCH DONE")


if __name__ == "__main__":
    main()
