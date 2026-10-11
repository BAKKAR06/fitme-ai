"""Backend tests with a fake GPU server.  Run:  python -m pytest backend/tests -q"""
import importlib
import io
import json
import sys
import time
from pathlib import Path

import pytest
from PIL import Image

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))


def png(color, size=(300, 400)):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "PNG")
    return buf.getvalue()


class FakeResp:
    def __init__(self, code=200, js=None, content=b"", ct="application/json"):
        self.status_code, self._js, self.content = code, js, content
        self.headers = {"content-type": ct}
        self.text = json.dumps(js)

    def json(self):
        return self._js


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("FITME_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("FITME_REMOTE_AI_URL", "http://gpu.local")
    monkeypatch.setenv("FITME_AI_PROVIDER", "kaggle")
    monkeypatch.setenv("FITME_API_KEY", "secret123")
    import app.main as m
    m = importlib.reload(m)
    calls = []

    def fake_post(url, **kw):
        calls.append(("POST", url, kw.get("data")))
        return FakeResp(js={"job_id": f"r{len(calls)}"})

    def fake_get(url, **kw):
        if url.endswith("/health"):
            return FakeResp(js={"status": "ready"})
        if url.endswith("/result"):
            return FakeResp(content=png("red"), ct="image/png")
        return FakeResp(js={"status": "completed"})

    monkeypatch.setattr(m.httpx, "post", fake_post)
    monkeypatch.setattr(m.httpx, "get", fake_get)
    from fastapi.testclient import TestClient

    c = TestClient(m.app)
    c.headers.update({"X-FitMe-Key": "secret123"})
    c.calls = calls
    return c


def wait_job(c, job_id):
    for _ in range(100):
        j = c.get(f"/api/v1/try-on/{job_id}").json()
        if j["status"] in ("completed", "failed"):
            return j
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def test_health_is_open_but_api_needs_key(client):
    from fastapi.testclient import TestClient
    import app.main as m

    anon = TestClient(m.app)
    assert anon.get("/health").json()["api_key_required"] is True
    assert anon.get("/api/v1/catalog").status_code == 401
    assert client.get("/api/v1/catalog").status_code == 200


def test_single_try_on_and_save_look(client):
    r = client.post(
        "/api/v1/try-on/upload",
        data={"category": "upper_body", "garment_photo_type": "model", "num_steps": "30", "seed": "7"},
        files={"person_photo": ("p.jpg", png("gray"), "image/png"), "garment_photo": ("g.png", png("navy"), "image/png")},
    )
    assert r.status_code == 200, r.text
    job = wait_job(client, r.json()["job_id"])
    assert job["status"] == "completed", job["error"]
    data = client.calls[0][2]
    assert data["garment_photo_type"] == "model" and data["num_timesteps"] == "30" and data["seed"] == "7"
    assert client.get(job["result_url"]).status_code == 200
    saved = client.post("/api/v1/looks/save", json={"job_id": job["job_id"]}).json()
    assert saved["status"] == "saved" and saved["look"]["total_steps"] == 1


def test_outfit_runs_bottoms_first_and_chains(client):
    items = [
        {"category": "upper_body", "photo_type": "flat-lay", "label": "Куртка", "upload_index": 0},
        {"category": "lower_body", "photo_type": "flat-lay", "label": "Джинсы", "upload_index": 1},
    ]
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(items)},
        files=[
            ("person_photo", ("p.jpg", png("gray"), "image/png")),
            ("garment_photos", ("a.png", png("black"), "image/png")),
            ("garment_photos", ("b.png", png("blue"), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    job = wait_job(client, r.json()["job_id"])
    assert job["status"] == "completed", job["error"]
    assert [it["label"] for it in job["items"]] == ["Джинсы", "Куртка"]
    assert job["total_steps"] == 2 and len(job["step_results"]) == 2
    cats = [c[2]["category"] for c in client.calls if c[0] == "POST"]
    assert cats == ["bottoms", "tops"]


def test_outfit_limits(client):
    too_many = [{"category": "upper_body", "upload_index": 0}] * 4
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(too_many)},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))],
    )
    assert r.status_code == 422
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps([{"category": "upper_body", "upload_index": 3}])},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png"))],
    )
    assert r.status_code == 422


def jpeg(color, size=(300, 400)):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "JPEG")
    return buf.getvalue()


def test_jpeg_result_keeps_jpg_extension(client, monkeypatch):
    import app.main as m

    def fake_get(url, **kw):
        if url.endswith("/health"):
            return FakeResp(js={"status": "ready", "upscaler": True})
        if url.endswith("/result"):
            return FakeResp(content=jpeg("red"), ct="image/jpeg")
        return FakeResp(js={"status": "completed"})

    monkeypatch.setattr(m.httpx, "get", fake_get)
    r = client.post(
        "/api/v1/try-on/upload",
        data={"category": "upper_body"},
        files={"person_photo": ("p.jpg", png("gray"), "image/png"), "garment_photo": ("g.png", png("navy"), "image/png")},
    )
    job = wait_job(client, r.json()["job_id"])
    assert job["status"] == "completed", job["error"]
    assert job["result_url"].endswith(".jpg")
    assert job["model"] == "fashn" and job["body_preprocessing"]["body_warped"] is False


def test_models_list_and_category_check(client, monkeypatch):
    import app.main as m

    monkeypatch.setattr(m, "_space_stage", lambda space_id: (space_id != "levihsu/OOTDiffusion", "SLEEPING"))
    data = client.get("/api/v1/models?refresh=true").json()
    by_id = {it["id"]: it for it in data["items"]}
    assert by_id["fashn"]["available"] is True
    assert by_id["leffa"]["available"] is True and by_id["ootd"]["available"] is False
    assert data["hf_token"] is False

    items = [{"category": "lower_body", "upload_index": 0}]
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(items), "model": "idm"},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))],
    )
    assert r.status_code == 422 and "IDM-VTON" in r.json()["detail"]
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(items), "model": "nope"},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))],
    )
    assert r.status_code == 422


def test_space_model_is_used(client, monkeypatch):
    import app.hf_space as hf

    used = []

    def fake_space(model_id, token, person, garment, category, steps, seed, photo_type):
        used.append((model_id, category, steps))
        return png("green")

    monkeypatch.setattr(hf, "space_try_on", fake_space)
    items = [{"category": "upper_body", "upload_index": 0, "label": "Футболка"}]
    r = client.post(
        "/api/v1/try-on/outfit",
        data={"items": json.dumps(items), "model": "leffa", "num_steps": "30"},
        files=[("person_photo", ("p.jpg", png("gray"), "image/png")), ("garment_photos", ("a.png", png("black"), "image/png"))],
    )
    assert r.status_code == 200, r.text
    job = wait_job(client, r.json()["job_id"])
    assert job["status"] == "completed", job["error"]
    assert used == [("leffa", "upper_body", 30)] and job["engine"] == "Leffa"
    assert not [c for c in client.calls if c[0] == "POST"]  # local GPU not touched
