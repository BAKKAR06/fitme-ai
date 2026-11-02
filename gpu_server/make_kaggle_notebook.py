"""Builds the private Kaggle notebook that adds Kaggle GPUs to the FitMe queue.

    gpu_server\\.venv\\Scripts\\python.exe gpu_server\\make_kaggle_notebook.py   (KAGGLE_GPU.bat)

1. Creates backend/data/kaggle.json once: a random ntfy topic + a random GPU key (both secret).
2. Writes KAGGLE_PRIVATE/FitMe_Kaggle_GPU.ipynb with the current fashn_server.py and enhance.py
   inside. The notebook starts one FASHN server per Kaggle GPU (T4 x2 -> two servers), opens a
   Cloudflare tunnel for each and posts the addresses to the topic. The backend on the laptop
   reads the topic (app/workers.py) and sends try-ons there with the key.

The notebook contains the key: keep it private on Kaggle and never commit it (git-ignored).
"""
from __future__ import annotations

import base64
import json
import secrets
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "backend" / "data" / "kaggle.json"
OUT_DIR = ROOT / "KAGGLE_PRIVATE"
OUT = OUT_DIR / "FitMe_Kaggle_GPU.ipynb"


def settings() -> dict:
    if SETTINGS.exists():
        data = json.loads(SETTINGS.read_text(encoding="utf-8"))
        if data.get("topic") and data.get("key"):
            return data
    data = {"topic": "fitme-gpu-" + secrets.token_hex(10), "key": secrets.token_urlsafe(24)}
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(data, indent=1), encoding="utf-8")
    return data


def md(text: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": text.strip("\n").splitlines(keepends=True)}


def code(text: str) -> dict:
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [],
            "source": text.strip("\n").splitlines(keepends=True)}


def build(cfg: dict) -> dict:
    files = {name: base64.b64encode((ROOT / "gpu_server" / name).read_bytes()).decode()
             for name in ("fashn_server.py", "enhance.py")}
    cells = [
        md("""
# FitMe — видеокарты Kaggle для очереди примерок

**Один раз:** Settings (справа) → **Accelerator: GPU T4 x2** · **Internet: On** (нужен подтверждённый телефон в Kaggle).

**Каждый запуск:** вверху **Save Version → Save & Run All (Commit)** → Save.
Блокнот работает в фоне (браузер можно закрыть) `HOURS` часов, сам сообщает свои адреса серверу FitMe на ноутбуке,
и примерки начинают идти параллельно: ноутбук + 2 видеокарты Kaggle.
Остановить раньше: Kaggle → Your Work → этот блокнот → версия → **Cancel run**.

Квота Kaggle — около 30 часов GPU в неделю. Ключ ниже секретный: блокнот должен быть **Private**.
"""),
        code(f"""
TOPIC = {cfg['topic']!r}   # секретный канал, по нему ноутбук находит эти видеокарты
GPU_KEY = {cfg['key']!r}   # секретный ключ: без него сервер Kaggle не примет запрос
HOURS = 11.5               # сколько часов держать видеокарты (максимум сессии Kaggle - 12)
DTYPE = 'fp16'             # T4 не умеет bfloat16; если картинки выходят чёрные/шумные - поставьте 'fp32'
"""),
        code("""
!nvidia-smi --query-gpu=name,memory.total --format=csv
%pip install -q "fashn-vton @ git+https://github.com/fashn-AI/fashn-vton-1.5.git" fastapi uvicorn python-multipart httpx
!wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /kaggle/working/cloudflared && chmod +x /kaggle/working/cloudflared
print('ok')
"""),
        code(f"""
import base64, os, urllib.request
from huggingface_hub import hf_hub_download

FILES = {json.dumps(files)}
os.makedirs('/kaggle/working/fitme', exist_ok=True)
for name, data in FILES.items():
    with open(f'/kaggle/working/fitme/{{name}}', 'wb') as fh:
        fh.write(base64.b64decode(data))

W = '/kaggle/working/weights'
os.makedirs(f'{{W}}/dwpose', exist_ok=True)
hf_hub_download('fashn-ai/fashn-vton-1.5', 'model.safetensors', local_dir=W)
for f in ('yolox_l.onnx', 'dw-ll_ucoco_384.onnx'):
    hf_hub_download('fashn-ai/DWPose', f, local_dir=f'{{W}}/dwpose')
if not os.path.exists(f'{{W}}/RealESRGAN_x4plus.pth'):
    urllib.request.urlretrieve('https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth',
                               f'{{W}}/RealESRGAN_x4plus.pth')
print('weights ready')
"""),
        code("""
import json, re, subprocess, time, requests, torch

N = torch.cuda.device_count()
print('GPUs:', N)
servers, tunnels, urls = [], {}, {}
for i in range(N):
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=str(i), FITME_GPU_PORT=str(7860 + i), FITME_GPU_KEY=GPU_KEY,
               FITME_DTYPE=DTYPE, FITME_WEIGHTS_DIR=W, PYTHONUNBUFFERED='1')
    log = open(f'/kaggle/working/server{i}.log', 'w')
    servers.append(subprocess.Popen(['python', '/kaggle/working/fitme/fashn_server.py'], cwd='/kaggle/working/fitme',
                                    env=env, stdout=log, stderr=subprocess.STDOUT))


def healthy(url, timeout=5):
    try:
        return requests.get(url + '/health', timeout=timeout).status_code == 200
    except Exception:
        return False


for i in range(N):
    for _ in range(300):
        if healthy(f'http://127.0.0.1:{7860 + i}'):
            break
        if servers[i].poll() is not None:
            break
        time.sleep(2)
    if not healthy(f'http://127.0.0.1:{7860 + i}'):
        print(open(f'/kaggle/working/server{i}.log').read()[-4000:])
        raise RuntimeError(f'GPU server {i} did not start')
    print('server', i, 'ready:', requests.get(f'http://127.0.0.1:{7860 + i}/health').json().get('gpu'))


def open_tunnel(i):
    old = tunnels.get(i)
    if old is not None:
        old.terminate()
    proc = subprocess.Popen(['/kaggle/working/cloudflared', 'tunnel', '--url', f'http://127.0.0.1:{7860 + i}',
                             '--no-autoupdate'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    tunnels[i] = proc
    deadline = time.time() + 90
    while time.time() < deadline:
        line = proc.stdout.readline()
        m = re.search(r'https://[-a-zA-Z0-9]+\\.trycloudflare\\.com', line or '')
        if m:
            urls[i] = m.group(0)
            break
    for _ in range(30):  # the new address needs a few seconds before it answers
        if i in urls and healthy(urls[i], 10):
            return urls[i]
        time.sleep(3)
    return urls.get(i)


def announce(active=True):
    msg = {'urls': [urls[i] for i in sorted(urls)] if active else [], 'until': time.time() + 600 if active else 0}
    try:
        requests.post(f'https://ntfy.sh/{TOPIC}', data=json.dumps(msg), timeout=15)
        print(time.strftime('%H:%M'), 'announced', msg['urls'])
    except Exception as exc:
        print('announce failed:', exc)


for i in range(N):
    print('tunnel', i, open_tunnel(i))
announce()
"""),
        code("""
# Держит видеокарты в очереди FitMe HOURS часов: проверяет туннели и каждые 5 минут
# повторяет адреса (ноутбук считает видеокарту живой, пока видит свежее сообщение).
from IPython.display import clear_output

end = time.time() + HOURS * 3600
last = 0
try:
    while time.time() < end:
        changed = False
        for i in range(N):
            if servers[i].poll() is not None:
                print(open(f'/kaggle/working/server{i}.log').read()[-3000:])
                raise RuntimeError(f'GPU server {i} stopped')
            if not healthy(urls.get(i, 'http://none'), 15):
                print('tunnel', i, 'dead -> new one:', open_tunnel(i))
                changed = True
        if changed or time.time() - last > 300:
            announce()
            last = time.time()
        time.sleep(60)
finally:
    announce(active=False)  # the laptop stops sending try-ons here right away
    print('stopped')
"""),
    ]
    return {"cells": cells, "metadata": {
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {"name": "python"},
        "kaggle": {"accelerator": "nvidiaTeslaT4", "isInternetEnabled": True, "isGpuEnabled": True},
    }, "nbformat": 4, "nbformat_minor": 5}


def main() -> None:
    cfg = settings()
    OUT_DIR.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(build(cfg), ensure_ascii=False, indent=1), encoding="utf-8")
    print("Notebook:", OUT)
    print("Settings:", SETTINGS, "(topic + key, secret)")


if __name__ == "__main__":
    main()
