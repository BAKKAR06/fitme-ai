"""
FitMe — сравнение моделей виртуальной примерки через бесплатные Hugging Face Spaces.

Работает без своего GPU: модели считаются на ZeroGPU (бесплатно, лимит по времени в день).
Без токена квота ~3 минуты/день на IP, с бесплатным токеном HF — больше (см. README).

Примеры:
    python bench_spaces.py --demo                      # скачать демо-набор и прогнать все модели
    python bench_spaces.py --models fashn,idm          # только выбранные модели
    python bench_spaces.py --grids-only                # пересобрать сравнительные картинки

Повторный запуск пропускает уже готовые результаты, поэтому тест можно растянуть на несколько дней.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import httpx
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent
TEST_DIR = ROOT / "test_set"
RESULTS_DIR = ROOT / "results"
PAIRS_FILE = TEST_DIR / "pairs.csv"
RESULTS_CSV = RESULTS_DIR / "results.csv"

CATEGORIES = ("upper_body", "lower_body", "dresses")

DEMO_BASE = "https://huggingface.co/spaces/yisol/IDM-VTON/resolve/main/example/"
DEMO_PEOPLE = ["human/00034_00.jpg", "human/00055_00.jpg", "human/01992_00.jpg"]
DEMO_GARMENTS = ["cloth/04469_00.jpg", "cloth/09163_00.jpg", "cloth/09263_00.jpg"]


class QuotaExceeded(RuntimeError):
    pass


# --------------------------------------------------------------------------- #
# Low-level Gradio HTTP client (works with Gradio 4.x, 5.x and 6.x servers)
# --------------------------------------------------------------------------- #
class Space:
    def __init__(self, space_id: str, token: str | None, timeout: float = 600.0):
        self.space_id = space_id
        self.host = "https://" + space_id.lower().replace("/", "-").replace(".", "-").replace("_", "-") + ".hf.space"
        headers = {"User-Agent": "FitMe-benchmark/1.0"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self.http = httpx.Client(headers=headers, timeout=httpx.Timeout(30.0, read=timeout), follow_redirects=True)
        try:
            info = self.http.get(f"https://huggingface.co/api/spaces/{space_id}").json()
            self.host = (info.get("host") or self.host).rstrip("/")
            stage = (info.get("runtime") or {}).get("stage")
            if stage and stage != "RUNNING":
                raise RuntimeError(f"Space {space_id} сейчас {stage}")
        except httpx.HTTPError:
            pass
        cfg =self.http.get(self.host + "/config").raise_for_status().json()
        self.prefix = cfg.get("api_prefix") or ""
        if self.prefix == "/":
            self.prefix = ""
        self.fn_index = {d.get("api_name"): i for i, d in enumerate(cfg.get("dependencies", [])) if d.get("api_name")}

    def upload(self, path: Path, max_side: int = 1280) -> dict[str, Any]:
        image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        image.thumbnail((max_side, max_side))
        buf = io.BytesIO()
        image.save(buf, format="JPEG", quality=95)
        r = self.http.post(self.host + self.prefix + "/upload", files={"files": (path.stem + ".jpg", buf.getvalue(), "image/jpeg")})
        r.raise_for_status()
        return {"path": r.json()[0], "meta": {"_type": "gradio.FileData"}}

    def call(self, api_name: str, data: list[Any]) -> tuple[list[Any], float | None]:
        api = api_name.lstrip("/")
        if api not in self.fn_index:
            raise RuntimeError(f"{self.space_id}: endpoint /{api} not found (Space changed?)")
        session = uuid.uuid4().hex[:11]
        join = self.http.post(
            self.host + self.prefix + "/queue/join",
            json={"data": data, "fn_index": self.fn_index[api], "session_hash": session, "event_data": None, "trigger_id": None},
        )
        join.raise_for_status()
        with self.http.stream("GET", self.host + self.prefix + "/queue/data", params={"session_hash": session}) as stream:
            for line in stream.iter_lines():
                if not line.startswith("data:"):
                    continue
                msg = json.loads(line[5:].strip())
                if msg.get("msg") != "process_completed":
                    continue
                out = msg.get("output") or {}
                if msg.get("success"):
                    return out.get("data") or [], out.get("duration")
                err = str(out.get("error") or msg.get("title") or "unknown error")
                if "quota" in err.lower():
                    raise QuotaExceeded(err)
                raise RuntimeError(err)
        raise RuntimeError("stream closed without result")

    def download(self, file_data: Any, dest: Path) -> None:
        while isinstance(file_data, list):  # Gallery -> first item
            file_data = file_data[0]
        if isinstance(file_data, dict) and "image" in file_data:  # Gallery item
            file_data = file_data["image"]
        url = file_data.get("url") if isinstance(file_data, dict) else None
        if not url:
            url = self.host + self.prefix + "/file=" + file_data["path"]
        r = self.http.get(url)
        r.raise_for_status()
        Image.open(io.BytesIO(r.content)).convert("RGB").save(dest, format="PNG")


def _strip(fd: Any) -> Any:
    if isinstance(fd, dict) and "path" in fd:
        return {"path": fd["path"], "meta": {"_type": "gradio.FileData"}}
    return fd


# --------------------------------------------------------------------------- #
# Model adapters
# --------------------------------------------------------------------------- #
@dataclass
class Model:
    key: str
    title: str
    space: str
    license: str
    categories: tuple[str, ...]
    run: Callable[[Space, Path, Path, str], tuple[Any, float | None]]


def run_fashn(s: Space, person: Path, garment: Path, category: str):
    cat = {"upper_body": "tops", "lower_body": "bottoms", "dresses": "one-pieces"}[category]
    data, dur = s.call("try_on", [s.upload(person), s.upload(garment), cat, "flat-lay", 30, 1.5, 42, True])
    return data[0], dur


def run_idm(s: Space, person: Path, garment: Path, category: str):
    p = s.upload(person)
    data, dur = s.call("tryon", [{"background": p, "layers": [], "composite": None}, s.upload(garment), "garment", True, True, 30, 42])
    return data[0], dur


def run_leffa(s: Space, person: Path, garment: Path, category: str):
    model_type = "viton_hd" if category == "upper_body" else "dress_code"
    data, dur = s.call("leffa_predict_vt", [s.upload(person), s.upload(garment), False, 30, 2.5, 42, model_type, category, False])
    return data[0], dur


def run_fitdit(s: Space, person: Path, garment: Path, category: str):
    cat = {"upper_body": "Upper-body", "lower_body": "Lower-body", "dresses": "Dresses"}[category]
    p = s.upload(person)
    mask, d1 = s.call("generate_mask", [p, cat, 0, 0, 0, 0])
    editor = mask[0]
    pre_mask = {
        "background": _strip(editor.get("background")),
        "layers": [_strip(x) for x in editor.get("layers") or []],
        "composite": _strip(editor.get("composite")),
        "id": None,
    }
    data, d2 = s.call("process", [p, s.upload(garment), pre_mask, _strip(mask[1]), 20, 2, 42, 1, "768x1024"])
    return data[0], (d1 or 0) + (d2 or 0)


def run_ootd(s: Space, person: Path, garment: Path, category: str):
    if category == "upper_body":
        data, dur = s.call("process_hd", [s.upload(person), s.upload(garment), 1, 20, 2, 42])
    else:
        cat = {"lower_body": "Lower-body", "dresses": "Dress"}[category]
        data, dur = s.call("process_dc", [s.upload(person), s.upload(garment), cat, 1, 20, 2, 42])
    return data[0], dur


MODELS: dict[str, Model] = {
    m.key: m
    for m in [
        Model("fashn", "FASHN VTON 1.5", "fashn-ai/fashn-vton-1.5", "Apache-2.0", CATEGORIES, run_fashn),
        Model("idm", "IDM-VTON", "yisol/IDM-VTON", "CC BY-NC-SA 4.0", ("upper_body",), run_idm),
        Model("leffa", "Leffa", "franciszzj/Leffa", "MIT (данные VITON-HD/DressCode)", CATEGORIES, run_leffa),
        Model("fitdit", "FitDiT", "BoyuanJiang/FitDiT", "CC BY-NC-SA 4.0", CATEGORIES, run_fitdit),
        Model("ootd", "OOTDiffusion", "levihsu/OOTDiffusion", "CC BY-NC-SA 4.0", CATEGORIES, run_ootd),
    ]
}


# --------------------------------------------------------------------------- #
# Test set, results, grids
# --------------------------------------------------------------------------- #
def download_demo() -> None:
    demo = TEST_DIR / "demo"
    demo.mkdir(parents=True, exist_ok=True)
    rows = []
    with httpx.Client(follow_redirects=True, timeout=60) as http:
        for rel in DEMO_PEOPLE + DEMO_GARMENTS:
            dest = demo / rel.replace("/", "_")
            if not dest.exists():
                dest.write_bytes(http.get(DEMO_BASE + rel).raise_for_status().content)
    for p in DEMO_PEOPLE:
        for g in DEMO_GARMENTS:
            rows.append({"person": f"demo/{p.replace('/', '_')}", "garment": f"demo/{g.replace('/', '_')}", "category": "upper_body"})
    write_pairs(rows)
    print(f"Демо-набор: {len(rows)} пар в {PAIRS_FILE}")


def write_pairs(rows: list[dict[str, str]]) -> None:
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with PAIRS_FILE.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["person", "garment", "category"])
        w.writeheader()
        w.writerows(rows)


def read_pairs() -> list[dict[str, str]]:
    if not PAIRS_FILE.exists():
        sys.exit(f"Нет {PAIRS_FILE}. Запусти с --demo или создай pairs.csv (person,garment,category).")
    pairs = []
    with PAIRS_FILE.open(encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            row = {k.strip(): (v or "").strip() for k, v in row.items()}
            if row.get("category") not in CATEGORIES:
                print(f"Пропуск: неизвестная категория {row}")
                continue
            for key in ("person", "garment"):
                if not (TEST_DIR / row[key]).exists():
                    sys.exit(f"Файл не найден: {TEST_DIR / row[key]}")
            pairs.append(row)
    return pairs


def pair_id(row: dict[str, str]) -> str:
    return f"{Path(row['person']).stem}__{Path(row['garment']).stem}"


def log_result(row: dict[str, Any]) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    new = not RESULTS_CSV.exists()
    with RESULTS_CSV.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["time", "model", "pair", "category", "ok", "wall_sec", "gpu_sec", "error"])
        if new:
            w.writeheader()
        w.writerow(row)


def build_grids(pairs: list[dict[str, str]], models: list[str]) -> None:
    out_dir = RESULTS_DIR / "grids"
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        font = ImageFont.truetype("arial.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    W, H, pad = 300, 400, 34
    for row in pairs:
        pid = pair_id(row)
        cells = [("Человек", TEST_DIR / row["person"]), ("Вещь", TEST_DIR / row["garment"])]
        cells += [(MODELS[m].title if m in MODELS else m, RESULTS_DIR / m / f"{pid}.png") for m in models]
        if not any(p.exists() for _, p in cells[2:]):
            continue
        grid = Image.new("RGB", (W * len(cells), H + pad), "white")
        draw = ImageDraw.Draw(grid)
        for i, (label, path) in enumerate(cells):
            draw.text((i * W + 8, 8), label, fill="black", font=font)
            if path.exists():
                img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
                img.thumbnail((W, H))
                grid.paste(img, (i * W + (W - img.width) // 2, pad + (H - img.height) // 2))
            else:
                draw.text((i * W + 8, pad + H // 2), "нет результата", fill="gray", font=font)
        grid.save(out_dir / f"{pid}.jpg", quality=90)
    print(f"Сравнительные картинки: {out_dir}")


def write_rating_template(pairs: list[dict[str, str]], models: list[str]) -> None:
    path = RESULTS_DIR / "ratings.csv"
    if path.exists():
        return
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["model", "pair", "вещь_похожа_1_5", "человек_узнаваем_1_5", "реализм_1_5", "посадка_1_5", "комментарий"])
        for row in pairs:
            for m in models:
                if (RESULTS_DIR / m / f"{pair_id(row)}.png").exists():
                    w.writerow([m, pair_id(row), "", "", "", "", ""])
    print(f"Шаблон ручной оценки: {path}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--demo", action="store_true", help="скачать демо-набор (3 человека x 3 вещи)")
    ap.add_argument("--models", default=",".join(MODELS), help="через запятую: " + ",".join(MODELS))
    ap.add_argument("--grids-only", action="store_true")
    ap.add_argument("--token", default=os.getenv("HF_TOKEN"), help="токен Hugging Face (или переменная HF_TOKEN)")
    args = ap.parse_args()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    unknown = [m for m in models if m not in MODELS]
    if unknown:
        sys.exit(f"Неизвестные модели: {unknown}. Доступны: {list(MODELS)}")

    if args.demo:
        download_demo()
    pairs = read_pairs()

    if not args.grids_only:
        if not args.token:
            print("ВНИМАНИЕ: без HF_TOKEN бесплатная квота GPU очень мала (Leffa не влезет вообще).")
        for key in models:
            model = MODELS[key]
            todo = [r for r in pairs if r["category"] in model.categories and not (RESULTS_DIR / key / f"{pair_id(r)}.png").exists()]
            if not todo:
                print(f"[{key}] всё уже готово")
                continue
            print(f"[{key}] {model.title}: {len(todo)} пар")
            try:
                space = Space(model.space, args.token)
            except Exception as exc:
                print(f"[{key}] Space недоступен: {exc}")
                continue
            (RESULTS_DIR / key).mkdir(parents=True, exist_ok=True)
            for row in todo:
                pid = pair_id(row)
                t0 = time.time()
                entry = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "model": key, "pair": pid, "category": row["category"]}
                try:
                    file_data, gpu = model.run(space, TEST_DIR / row["person"], TEST_DIR / row["garment"], row["category"])
                    space.download(file_data, RESULTS_DIR / key / f"{pid}.png")
                    entry.update(ok=1, wall_sec=round(time.time() - t0, 1), gpu_sec=round(gpu or 0, 1), error="")
                    print(f"  ok  {pid}  {entry['wall_sec']} c")
                    log_result(entry)
                except QuotaExceeded as exc:
                    print(f"  квота ZeroGPU закончилась для {key}: {exc}\n  Продолжи завтра — готовые результаты сохранены.")
                    break
                except Exception as exc:
                    entry.update(ok=0, wall_sec=round(time.time() - t0, 1), gpu_sec="", error=f"{type(exc).__name__}: {str(exc)[:300]}")
                    print(f"  ERR {pid}: {entry['error']}")
                    log_result(entry)

    all_dirs = sorted(p.name for p in RESULTS_DIR.iterdir() if p.is_dir() and p.name != "grids") if RESULTS_DIR.exists() else []
    build_grids(pairs, all_dirs)
    write_rating_template(pairs, all_dirs)


if __name__ == "__main__":
    main()
