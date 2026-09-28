from __future__ import annotations

import re
import sys
from pathlib import Path

import httpx

BASE_DIR = Path(__file__).resolve().parent
URL_FILE = BASE_DIR / "data" / "remote_ai_url.txt"
URL_FILE.parent.mkdir(parents=True, exist_ok=True)


def normalize(raw: str) -> str:
    value = (raw or "").strip()
    if not value:
        return ""

    match = re.search(r"https?://[^\s\"']+", value, flags=re.IGNORECASE)
    if match:
        value = match.group(0)
    else:
        value = value.strip().strip("\"'")
        if value.lower().startswith("set "):
            value = value[4:].strip().strip("\"'")
        if "=" in value:
            left, right = value.split("=", 1)
            if "url" in left.lower():
                value = right.strip().strip("\"'")
        value = value.strip().rstrip("/")
        if value and not value.lower().startswith(("http://", "https://")):
            value = "https://" + value

    return value.strip().strip("\"'").rstrip("/")


print()
print("===============================================================")
print("FitMe CLEAN MVP — Kaggle FASHN URL")
print("===============================================================")
print("В Kaggle Run All. В конце будет строка:")
print("FITME_AI_URL=https://....trycloudflare.com")
print()
print("Можно вставить всю строку целиком.")
print()

for attempt in range(1, 4):
    raw = input("Вставь FITME_AI_URL: ").strip()
    url = normalize(raw)

    if not url:
        print("URL пустой.\n")
        continue

    print(f"Проверяю: {url}/health")

    try:
        response = httpx.get(
            f"{url}/health",
            timeout=15.0,
            follow_redirects=True,
        )
        if response.status_code == 200:
            URL_FILE.write_text(url, encoding="utf-8")
            print("OK: FASHN сервер доступен.")
            print(f"Сохранено: {URL_FILE}")
            sys.exit(0)

        print(f"Сервер ответил HTTP {response.status_code}.")
        print(response.text[:500])
    except Exception as exc:
        print(f"Не удалось подключиться: {type(exc).__name__}: {exc}")

    print()

print("URL не прошёл проверку. Проверь, что Kaggle session ещё запущена.")
sys.exit(1)
