"""FitMe GPU self-test: quality v3 check on the local FASHN server.

Runs the same try-on three ways and saves a side-by-side picture to test_output/
(git-ignored: it may contain your own photo):
  1) plain FASHN output (30 steps, like v2)
  2) v3 enhanced (crop to person + Real-ESRGAN + paste-back into the original photo), 30 steps
  3) v3 enhanced, 50 steps ("Максимум")
Person photo: the newest photo sent from the phone (backend/uploads), else a demo photo.
"""
import io
import json
import sys
import time
import urllib.request
import uuid
from pathlib import Path

from PIL import Image, ImageDraw

SERVER = "http://127.0.0.1:7860"
BASE = "https://huggingface.co/spaces/yisol/IDM-VTON/resolve/main/example/"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "test_output"
OUT.mkdir(exist_ok=True)


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


def person_photo() -> tuple[str, bytes]:
    uploads = sorted((ROOT / "backend" / "uploads").glob("*_person.*"), key=lambda p: p.stat().st_mtime)
    if uploads:
        return uploads[-1].name, uploads[-1].read_bytes()
    return "demo 00034_00.jpg", get(BASE + "human/00034_00.jpg")


def run(person, garment, steps, enhance):
    t0 = time.time()
    job = post_multipart(SERVER + "/jobs",
                         {"category": "tops", "garment_photo_type": "auto", "num_timesteps": steps,
                          "guidance_scale": 1.5, "seed": 42, "segmentation_free": "true",
                          "enhance": "true" if enhance else "false"},
                         {"person_photo": ("p.jpg", person), "garment_photo": ("g.jpg", garment)})
    jid = job["job_id"]
    while True:
        st = json.loads(get(f"{SERVER}/jobs/{jid}"))
        if st["status"] in ("completed", "failed"):
            break
        time.sleep(0.5)
    if st["status"] == "failed":
        print(f"steps={steps} enhance={enhance} FAILED: {st.get('error')}")
        sys.exit(1)
    img = Image.open(io.BytesIO(get(f"{SERVER}/jobs/{jid}/result"))).convert("RGB")
    print(f"steps={steps} enhance={enhance}: total {time.time() - t0:.1f}s, gpu {st.get('seconds')}s, "
          f"peak VRAM {st.get('peak_vram_gb')} GB, size {img.size}, cropped={st.get('cropped')}")
    return img


health = json.loads(get(SERVER + "/health"))
print("health:", health)
name, person = person_photo()
print("person photo:", name)
garment = get(BASE + "cloth/04469_00.jpg")

shots = [
    ("v2: FASHN 30", run(person, garment, 30, False)),
    ("v3: 30 + enhance", run(person, garment, 30, True)),
    ("v3: 50 + enhance", run(person, garment, 50, True)),
]

# Side-by-side at a common height + zoomed head/chest crops to judge sharpness.
H = 1200
cols = []
for title, img in shots:
    w = int(img.width * H / img.height)
    full = img.resize((w, H), Image.Resampling.LANCZOS)
    zoom_box = (int(img.width * 0.25), int(img.height * 0.05), int(img.width * 0.75), int(img.height * 0.40))
    zoom = img.crop(zoom_box)
    zoom = zoom.resize((w, int(zoom.height * w / zoom.width)), Image.Resampling.LANCZOS)
    col = Image.new("RGB", (w, H + zoom.height + 40), "white")
    col.paste(full, (0, 40))
    col.paste(zoom, (0, H + 40))
    ImageDraw.Draw(col).text((10, 10), title, fill="black")
    cols.append(col)
sheet = Image.new("RGB", (sum(c.width for c in cols) + 20 * (len(cols) - 1), max(c.height for c in cols)), "white")
x = 0
for c in cols:
    sheet.paste(c, (x, 0))
    x += c.width + 20
sheet.save(OUT / "quality_v3_compare.jpg", quality=90)
print("saved test_output/quality_v3_compare.jpg")
print("SELFTEST OK")
