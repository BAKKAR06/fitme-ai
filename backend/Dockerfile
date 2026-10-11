# FitMe backend for a free Hugging Face Docker Space (CPU basic).
FROM python:3.11-slim

RUN useradd -m -u 1000 user
WORKDIR /app

COPY requirements.txt requirements-cutout.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
 && (pip install --no-cache-dir -r requirements-cutout.txt || echo "rembg skipped: avatar cutout disabled")

COPY app ./app

ENV FITME_STORAGE_DIR=/tmp/fitme \
    FITME_AI_PROVIDER=auto \
    U2NET_HOME=/tmp/u2net \
    PYTHONUNBUFFERED=1

USER user
EXPOSE 7860
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "7860"]
