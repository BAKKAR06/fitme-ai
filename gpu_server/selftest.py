"""Quick FitMe GPU self-test: one try-on on the local FASHN server, timing + VRAM."""
import json
import sys
import time
import urllib.request
import uuid
from pathlib import Path

SERVER = "http://127.0.0.1:7860"
BASE = "https://huggingface.co/spaces/yisol/IDM-VTON/resolve/main/example/"
OUT = Path(__file__).resolve().parent.parent / "docs"
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


print("health:", json.loads(get(SERVER + "/health")))
person = get(BASE + "human/00034_00.jpg")
garment = get(BASE + "cloth/04469_00.jpg")

for steps in (10, 30):
    t0 = time.time()
    job = post_multipart(SERVER + "/jobs",
                         {"category": "tops", "garment_photo_type": "flat-lay", "num_timesteps": steps,
                          "guidance_scale": 1.5, "seed": 42, "segmentation_free": "true"},
                         {"person_photo": ("p.jpg", person), "garment_photo": ("g.jpg", garment)})
    jid = job["job_id"]
    while True:
        st = json.loads(get(f"{SERVER}/jobs/{jid}"))
        if st["status"] in ("completed", "failed"):
            break
        time.sleep(0.5)
    if st["status"] == "failed":
        print(f"steps={steps} FAILED: {st.get('error')}")
        sys.exit(1)
    (OUT / f"local_gpu_test_{steps}steps.png").write_bytes(get(f"{SERVER}/jobs/{jid}/result"))
    print(f"steps={steps}: total {time.time() - t0:.1f}s, gpu {st.get('seconds')}s, peak VRAM {st.get('peak_vram_gb')} GB")
print("SELFTEST OK")
