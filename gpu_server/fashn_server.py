from __future__ import annotations

import io
import os
import threading
import time
import uuid

import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from huggingface_hub import hf_hub_download
from PIL import Image, ImageOps
from fashn_vton import TryOnPipeline

"""FitMe local GPU server: FASHN VTON 1.5 on your own NVIDIA card (8 GB is enough).

Same async API as the Kaggle notebook (/health, /jobs, /jobs/{id}, /jobs/{id}/result),
so the backend uses it exactly like Kaggle (FITME_REMOTE_AI_URL=http://127.0.0.1:7860).
"""
from pathlib import Path

WEIGHTS_DIR = os.getenv("FITME_WEIGHTS_DIR") or str(Path(__file__).resolve().parent / "weights")
os.makedirs(WEIGHTS_DIR, exist_ok=True)
os.makedirs(os.path.join(WEIGHTS_DIR, "dwpose"), exist_ok=True)

print("Downloading/checking FASHN weights...")
hf_hub_download(
    repo_id="fashn-ai/fashn-vton-1.5",
    filename="model.safetensors",
    local_dir=WEIGHTS_DIR,
)
for filename in ("yolox_l.onnx", "dw-ll_ucoco_384.onnx"):
    hf_hub_download(
        repo_id="fashn-ai/DWPose",
        filename=filename,
        local_dir=os.path.join(WEIGHTS_DIR, "dwpose"),
    )

if not torch.cuda.is_available():
    raise RuntimeError("CUDA GPU not found. Check NVIDIA driver and that PyTorch with CUDA is installed (INSTALL_LOCAL_GPU.bat).")

if torch.cuda.get_device_properties(0).major >= 8:
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True

print("GPU:", torch.cuda.get_device_name(0))
print("Loading FASHN VTON 1.5...")
pipeline = TryOnPipeline(weights_dir=WEIGHTS_DIR, device="cuda")
print("FASHN READY")

import numpy as np

# Human-parser classes that mean "a person is on the garment photo".
BODY_LABEL_IDS = [1, 2, 12, 13, 14, 15, 16]  # face, hair, arms, hands, legs, feet, torso
MODEL_PHOTO_BODY_SHARE = 0.015


def detect_garment_photo_type(garment_rgb):
    """flat-lay = garment alone (whole image is used); model = worn by a person
    (FASHN then cuts out only the garment, so hands/faces of the model are not copied)."""
    seg = pipeline.hp_model.predict(np.asarray(garment_rgb))
    share = float(np.isin(seg, BODY_LABEL_IDS).mean())
    return ("model" if share > MODEL_PHOTO_BODY_SHARE else "flat-lay"), share


app = FastAPI(title="FitMe FASHN Local GPU", version="1.3-local")
MAX_RESULTS = 30
pipeline_lock = threading.Lock()
jobs_lock = threading.Lock()
JOBS = {}
RESULTS = {}

CATEGORY_MAP = {
    "upper_body": "tops",
    "lower_body": "bottoms",
    "dresses": "one-pieces",
    "tops": "tops",
    "bottoms": "bottoms",
    "one-pieces": "one-pieces",
}


@app.get("/health")
def health():
    free, total = torch.cuda.mem_get_info()
    return {
        "status": "ready",
        "engine": "FASHN VTON 1.5",
        "mode": "async-jobs-local",
        "gpu": torch.cuda.get_device_name(0),
        "vram_free_gb": round(free / 2**30, 2),
        "vram_total_gb": round(total / 2**30, 2),
    }


def generate_job(
    job_id: str,
    person_bytes: bytes,
    garment_bytes: bytes,
    category: str,
    garment_photo_type: str,
    num_timesteps: int,
    guidance_scale: float,
    seed: int,
    segmentation_free: bool,
):
    try:
        with jobs_lock:
            JOBS[job_id]["status"] = "processing"
            JOBS[job_id]["started_at"] = time.time()

        person = Image.open(io.BytesIO(person_bytes))
        person = ImageOps.exif_transpose(person).convert("RGB")
        garment = Image.open(io.BytesIO(garment_bytes))
        garment = ImageOps.exif_transpose(garment).convert("RGB")

        mapped = CATEGORY_MAP.get(category, "tops")
        if garment_photo_type in {"flat-lay", "model"}:
            photo_type = garment_photo_type
        else:  # "auto": look for a person (face/hair/arms/hands/legs/feet/torso) on the garment photo
            with pipeline_lock:
                photo_type, body_share = detect_garment_photo_type(garment)
            with jobs_lock:
                JOBS[job_id]["body_share_on_garment_photo"] = round(body_share, 4)
        with jobs_lock:
            JOBS[job_id]["garment_photo_type"] = photo_type
        steps = max(10, min(int(num_timesteps), 50))
        cfg = max(1.0, min(float(guidance_scale), 3.0))

        with pipeline_lock:
            torch.cuda.reset_peak_memory_stats()
            result = pipeline(
                person_image=person,
                garment_image=garment,
                category=mapped,
                garment_photo_type=photo_type,
                num_samples=1,
                num_timesteps=steps,
                guidance_scale=cfg,
                seed=int(seed),
                segmentation_free=bool(segmentation_free),
            )

        output = io.BytesIO()
        result.images[0].save(output, format="PNG")

        with jobs_lock:
            RESULTS[job_id] = output.getvalue()
            JOBS[job_id]["status"] = "completed"
            JOBS[job_id]["completed_at"] = time.time()
            JOBS[job_id]["seconds"] = round(time.time() - JOBS[job_id]["started_at"], 2)
            JOBS[job_id]["peak_vram_gb"] = round(torch.cuda.max_memory_allocated() / 2**30, 2)
            while len(RESULTS) > MAX_RESULTS:  # keep RAM bounded
                RESULTS.pop(next(iter(RESULTS)))

    except Exception as exc:
        with jobs_lock:
            JOBS[job_id]["status"] = "failed"
            JOBS[job_id]["error"] = f"{type(exc).__name__}: {str(exc)[:1000]}"
    finally:
        torch.cuda.empty_cache()


@app.post("/jobs")
async def create_job(
    person_photo: UploadFile = File(...),
    garment_photo: UploadFile = File(...),
    category: str = Form("tops"),
    garment_photo_type: str = Form("flat-lay"),
    num_timesteps: int = Form(20),
    guidance_scale: float = Form(1.5),
    seed: int = Form(42),
    segmentation_free: bool = Form(True),
):
    person_bytes = await person_photo.read()
    garment_bytes = await garment_photo.read()

    if not person_bytes or not garment_bytes:
        raise HTTPException(status_code=400, detail="Empty input image")

    job_id = uuid.uuid4().hex[:12]
    with jobs_lock:
        JOBS[job_id] = {
            "job_id": job_id,
            "status": "queued",
            "created_at": time.time(),
            "error": None,
        }

    threading.Thread(
        target=generate_job,
        args=(
            job_id,
            person_bytes,
            garment_bytes,
            category,
            garment_photo_type,
            num_timesteps,
            guidance_scale,
            seed,
            segmentation_free,
        ),
        daemon=True,
        name=f"fashn-{job_id}",
    ).start()

    return {"job_id": job_id, "status": "queued"}


@app.get("/jobs/{job_id}")
def job_status(job_id: str):
    with jobs_lock:
        job = JOBS.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        return dict(job)


@app.get("/jobs/{job_id}/result")
def job_result(job_id: str):
    with jobs_lock:
        job = JOBS.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        if job.get("status") != "completed":
            raise HTTPException(status_code=409, detail=job.get("status"))
        data = RESULTS.get(job_id)

    if not data:
        raise HTTPException(status_code=404, detail="Result not found")

    return Response(content=data, media_type="image/png")


# Short sync route kept only for quick manual tests.
@app.post("/tryon")
async def tryon_sync_disabled():
    raise HTTPException(
        status_code=410,
        detail="Use async /jobs endpoint in CLEAN MVP v2",
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host=os.getenv("FITME_GPU_HOST", "127.0.0.1"),
        port=int(os.getenv("FITME_GPU_PORT", "7860")),
    )
