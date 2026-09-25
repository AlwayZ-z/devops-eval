# ---------- Stage 1 : builder ----------
# Image de base precise (pas de tag "latest"), variante slim.
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- Stage 2 : image finale ----------
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}"

WORKDIR /app

# On ne recupere que les dependances installees, sans pip cache ni outils de build.
COPY --from=builder /install /usr/local
COPY app.py .

# L'application ne tourne pas en root.
RUN useradd --create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

# Healthcheck reel : interroge /health, qui verifie lui-meme Redis.
# On utilise python et pas curl, absent de l'image slim.
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health').status == 200 else 1)"

# Un seul worker : les metriques Prometheus sont tenues en memoire du process.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "4", "app:app"]
