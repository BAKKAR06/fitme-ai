"""FitMe v4 lab, part 3: candidate "v4b" pipeline built from what parts 1-2 showed (experiment only).

Part 1 showed that the seed changes garment similarity much more than any other knob
(one pair: 0.72 .. 0.87 between seeds), guidance 2.5 helps a little on average, and the
garment cut-out ("prep") and the zoom pass do not help. So v4b is:
    the app's own pipeline with guidance 2.5 -> generate several seeds, keep the most
    faithful one (DINOv2 similarity to the garment photo).

Variants (all with the server's own finish: crop + Real-ESRGAN + paste-back):
  b30      1 seed  x 30 steps   (same time as the app today)
  b30x2    best of 2 seeds x 30 steps   (~2x time)
  b15x2    best of 2 seeds x 15 steps   (~same time as today)
  b15x3    best of 3 seeds x 15 steps   (~1.5x time)
NB: the pick uses the same similarity score as the table, so the numbers of the "best of"
rows are optimistic - judge them by the pictures in grid3_*.jpg too.
    gpu_server\\.venv\\Scripts\\python.exe experiments\\v4_lab3.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "gpu_server"))
sys.path.insert(0, str(ROOT / "experiments"))

import v4_lab as lab  # noqa: E402

# The server does crop + upscale + paste-back itself (enhance=true). Part 2 showed that its
# colour shift changes nothing measurable, and a second CUDA model in this process made the
# laptop GPU spill into shared memory (35 s per step instead of 1.5 s).
GUIDANCE = 2.5


def main():
    OUT = lab.OUT
    catalog = {i["item_id"]: i for i in json.loads((ROOT / "backend/data/catalog.json").read_text(encoding="utf-8"))}
    rfile = OUT / "results.json"
    results = json.loads(rfile.read_text(encoding="utf-8"))
    names = ("b30", "b30x2", "b15x2", "b15x3")

    def save():
        rfile.write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")

    for idx, (pfile, gid, cat) in enumerate(lab.PAIRS):
        pid = f"p{idx + 1}_{cat.split('_')[0]}"
        if pid in results and results[pid].get("_lab3") != 2:
            # rows of the first attempt used a local finish; measure everything the same way
            for k in names:
                results[pid].pop(k, None)
            results[pid]["_lab3"] = 2
            save()
        if pid not in results or all(k in results[pid] for k in names):
            continue
        person = ImageOps.exif_transpose(Image.open(ROOT / "backend/uploads" / pfile)).convert("RGB")
        person.thumbnail((2400, 2400))
        garment_bytes = (ROOT / "backend/catalog" / catalog[gid]["file_name"]).read_bytes()
        ref = lab.embed(Image.open(OUT / pid / "0_garment_ref.jpg"))
        seg_p = lab.parse(person)
        person_bytes = lab.to_jpeg(person)
        cands = {}  # (steps, seed) -> (fidelity, image, secs, row)

        def gen(steps, seed):
            if (steps, seed) in cands:
                return cands[(steps, seed)]
            lab.STEPS = steps
            img, secs = lab.tryon(person_bytes, garment_bytes, cat, GUIDANCE, seed, enhance=True)
            seg_r, mask = lab.garment_region(img, cat)
            row = {"fidelity": round(lab.fidelity(ref, img, mask), 4),
                   "sharpness": round(lab.sharpness(img, mask), 1),
                   "preservation": round(lab.preservation(person, img, seg_p, seg_r), 4)}
            cands[(steps, seed)] = (row["fidelity"], img, secs, row)
            lab.log(pid, f"  cand {steps} steps seed {seed}", row, secs, "s")
            return cands[(steps, seed)]

        def pick(name, keys):
            try:
                got = [gen(*k) for k in keys]
                best = max(got, key=lambda c: c[0])
                row = dict(best[3], secs=round(sum(c[2] for c in got), 1), size=list(best[1].size),
                           picked=f"{keys[got.index(best)][1]}")
                best[1].save(OUT / pid / f"{name}.jpg", quality=92)
                results[pid][name] = row
                save()
                lab.log(pid, name, row)
            except Exception as exc:
                lab.log(pid, name, "FAILED", type(exc).__name__, str(exc)[:300])

        pick("b30", [(30, 42)])
        pick("b30x2", [(30, 42), (30, 7)])
        pick("b15x2", [(15, 42), (15, 7)])
        pick("b15x3", [(15, 42), (15, 7), (15, 1234)])
        lab.STEPS = 30

    # ---- table over everything measured so far
    variants = ["v2", "v3", "nocolor", "g2.5", "best4", "prep", "zoom", "zoom2", "v4", *names]
    lines = ["| вариант | n | сходство вещи ↑ | детализация ↑ | сохранность лица/фона ↑ | время, с |",
             "|---|---|---|---|---|---|"]
    for v in variants:
        rows = [r[v] for r in results.values() if isinstance(r, dict) and v in r]
        if rows:
            s = {k: float(np.mean([x[k] for x in rows])) for k in ("fidelity", "sharpness", "preservation", "secs")}
            lines.append(f"| {v} | {len(rows)} | {s['fidelity']:.3f} | {s['sharpness']:.0f} | {s['preservation']:.3f} | {s['secs']:.0f} |")
    (OUT / "summary3.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    lab.log("\n" + "\n".join(lines))

    # ---- grids: person | garment | v3 (app today) | nocolor | b15x2 | b30x2
    for pid, r in results.items():
        tiles = [("photo", OUT / pid / "0_person.jpg"), ("garment", OUT / pid / "0_garment_ref.jpg")]
        tiles += [(v, OUT / pid / f"{v}.jpg") for v in ("v3", "nocolor", "b15x2", "b30x2") if v in r]
        ims = []
        for label, path in tiles:
            if not path.exists():
                continue
            im = ImageOps.pad(Image.open(path).convert("RGB"), (400, 600), color="white")
            d = ImageDraw.Draw(im)
            d.rectangle((0, 0, 400, 28), fill="black")
            f = r.get(label, {}).get("fidelity")
            d.text((8, 7), label + (f"  F={f:.3f}" if f else ""), fill="white")
            ims.append(im)
        if ims:
            grid = Image.new("RGB", (400 * len(ims), 600), "white")
            for i, im in enumerate(ims):
                grid.paste(im, (400 * i, 0))
            grid.save(OUT / f"grid3_{pid}.jpg", quality=88)
    lab.log("LAB3 DONE")


if __name__ == "__main__":
    main()
