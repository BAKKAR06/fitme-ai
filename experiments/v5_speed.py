"""FitMe v5 speed lab: how fast can one laptop GPU make a try-on, and what does it cost in quality?

Same 8 photo pairs and the same metrics as the v4 lab (garment similarity, detail, face/background
kept), but every variant is measured in one run so the timings are comparable.

  s30     30 steps + Real-ESRGAN finish        (the app today)
  s20     20 steps + finish
  s15     15 steps + finish
  s15nu   15 steps, finish WITHOUT the upscaler (crop + paste-back only)
  s10     10 steps + finish                    ("draft")
  s15x2   15 steps, 2 variants in ONE batch, the more faithful one kept

Time = seconds the GPU server spent on the job (upload/download excluded).
Results: test_output/v5_speed/ (summary5.md, grid5_<pair>.jpg) - contains your photos, git-ignored.

    gpu_server\\.venv\\Scripts\\python.exe experiments\\v5_speed.py
"""
from __future__ import annotations

import io
import json
import sys
import time
import urllib.request
import uuid
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "experiments"))

import v4_lab as lab  # noqa: E402  (loads the parser + DINOv2 on the CPU)

OUT = ROOT / "test_output" / "v5_speed"
OUT.mkdir(parents=True, exist_ok=True)
lab.LOG = OUT / "lab_log.txt"
GUIDANCE = 2.5
VARIANTS = {  # name: (steps, upscale, samples)
    "s30": (30, True, 1),
    "s20": (20, True, 1),
    "s15": (15, True, 1),
    "s15nu": (15, False, 1),
    "s10": (10, True, 1),
    "s15x2": (15, True, 2),
}


def catalog() -> dict:
    data = ROOT / "backend" / "data"
    for name in ("catalog.json", "catalog.json.migrated"):
        if (data / name).exists():
            return {i["item_id"]: i for i in json.loads((data / name).read_text(encoding="utf-8"))}
    raise SystemExit("backend/data/catalog.json not found")


def run_job(person: bytes, garment: bytes, cat: str, steps: int, upscale: bool, samples: int, seed: int = 42):
    boundary = uuid.uuid4().hex
    fields = {"category": lab.CATEGORY[cat], "garment_photo_type": "auto", "num_timesteps": steps,
              "guidance_scale": GUIDANCE, "seed": seed, "segmentation_free": "true", "enhance": "true",
              "upscale": "true" if upscale else "false", "num_samples": samples}
    body = b""
    for k, v in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    for k, data in (("person_photo", person), ("garment_photo", garment)):
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{k}.jpg"\r\n'
                 "Content-Type: image/jpeg\r\n\r\n").encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(lab.SERVER + "/jobs", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        jid = json.loads(r.read())["job_id"]
    while True:
        st = json.loads(lab.http_get(f"{lab.SERVER}/jobs/{jid}"))
        if st["status"] in ("completed", "failed"):
            break
        time.sleep(0.5)
    if st["status"] == "failed":
        raise RuntimeError(st.get("error"))
    images = [Image.open(io.BytesIO(lab.http_get(f"{lab.SERVER}/jobs/{jid}/result?index={i}"))).convert("RGB")
              for i in range(int(st.get("samples") or 1))]
    return images, float(st.get("seconds") or 0), float(st.get("peak_vram_gb") or 0)


def main():
    health = json.loads(lab.http_get(lab.SERVER + "/health"))
    lab.log("GPU server:", health.get("gpu"), "| version must support upscale/num_samples (1.6+)")
    cat_items = catalog()
    rfile = OUT / "results.json"
    results = json.loads(rfile.read_text(encoding="utf-8")) if rfile.exists() else {}

    def save():
        rfile.write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")

    # warm-up: the first job after a start is slower (CUDA kernels, caches)
    first = lab.PAIRS[0]
    p0 = ImageOps.exif_transpose(Image.open(ROOT / "backend/uploads" / first[0])).convert("RGB")
    p0.thumbnail((2400, 2400))
    run_job(lab.to_jpeg(p0), (ROOT / "backend/catalog" / cat_items[first[1]]["file_name"]).read_bytes(), first[2], 10, True, 1)

    for idx, (pfile, gid, cat) in enumerate(lab.PAIRS):
        pid = f"p{idx + 1}_{cat.split('_')[0]}"
        results.setdefault(pid, {})
        if all(v in results[pid] for v in VARIANTS):
            continue
        (OUT / pid).mkdir(exist_ok=True)
        person = ImageOps.exif_transpose(Image.open(ROOT / "backend/uploads" / pfile)).convert("RGB")
        person.thumbnail((2400, 2400))
        person.save(OUT / pid / "0_person.jpg", quality=90)
        garment_bytes = (ROOT / "backend/catalog" / cat_items[gid]["file_name"]).read_bytes()
        Image.open(io.BytesIO(garment_bytes)).convert("RGB").save(OUT / pid / "0_garment.jpg", quality=90)
        ref = lab.embed(Image.open(io.BytesIO(garment_bytes)))
        seg_p = lab.parse(person)
        person_bytes = lab.to_jpeg(person)

        for name, (steps, upscale, samples) in VARIANTS.items():
            if name in results[pid]:
                continue
            try:
                images, secs, vram = run_job(person_bytes, garment_bytes, cat, steps, upscale, samples)
                scored = []
                for img in images:
                    seg_r, mask = lab.garment_region(img, cat)
                    scored.append(({"fidelity": round(lab.fidelity(ref, img, mask), 4),
                                    "sharpness": round(lab.sharpness(img, mask), 1),
                                    "preservation": round(lab.preservation(person, img, seg_p, seg_r), 4)}, img))
                row, img = max(scored, key=lambda x: x[0]["fidelity"])
                row |= {"secs": round(secs, 1), "vram_gb": vram, "samples": len(images)}
                img.save(OUT / pid / f"{name}.jpg", quality=92)
                results[pid][name] = row
                lab.log(pid, name, row)
            except Exception as exc:
                results[pid][name] = {"error": f"{type(exc).__name__}: {str(exc)[:300]}"}
                lab.log(pid, name, "FAILED", results[pid][name]["error"])
            save()

    # ---- summary
    lines = ["| вариант | шаги | n | сходство вещи ↑ | детализация ↑ | лицо/фон ↑ | время GPU, с | примерок в час |",
             "|---|---|---|---|---|---|---|---|"]
    for name, (steps, upscale, samples) in VARIANTS.items():
        rows = [r[name] for r in results.values() if name in r and "error" not in r[name]]
        if not rows:
            errors = [r[name]["error"] for r in results.values() if name in r]
            lines.append(f"| {name} | {steps} | 0 | ошибка: {errors[0][:80] if errors else '-'} | | | | |")
            continue
        m = {k: float(np.mean([x[k] for x in rows])) for k in ("fidelity", "sharpness", "preservation", "secs")}
        lines.append(f"| {name} | {steps}{'' if upscale else ' (без апскейла)'}{' ×2' if samples > 1 else ''} | "
                     f"{len(rows)} | {m['fidelity']:.3f} | {m['sharpness']:.0f} | {m['preservation']:.3f} | "
                     f"{m['secs']:.1f} | {int(3600 // max(m['secs'], 1))} |")
    (OUT / "summary5.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    lab.log("\n" + "\n".join(lines))

    for pid, r in results.items():
        tiles = [("photo", OUT / pid / "0_person.jpg", None), ("garment", OUT / pid / "0_garment.jpg", None)]
        tiles += [(v, OUT / pid / f"{v}.jpg", r.get(v)) for v in VARIANTS]
        ims = []
        for label, path, row in tiles:
            if not path.exists():
                continue
            im = ImageOps.pad(Image.open(path).convert("RGB"), (360, 540), color="white")
            d = ImageDraw.Draw(im)
            d.rectangle((0, 0, 360, 26), fill="black")
            extra = f"  {row['secs']:.0f}s F={row['fidelity']:.3f}" if row and "secs" in row else ""
            d.text((6, 6), label + extra, fill="white")
            ims.append(im)
        grid = Image.new("RGB", (360 * len(ims), 540), "white")
        for i, im in enumerate(ims):
            grid.paste(im, (360 * i, 0))
        grid.save(OUT / f"grid5_{pid}.jpg", quality=88)
    lab.log("LAB5 DONE")


if __name__ == "__main__":
    main()
