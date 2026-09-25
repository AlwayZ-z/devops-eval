"""API HTTP de demonstration - evaluation DevOps ESIEA.

Expose des endpoints applicatifs, un healthcheck qui verifie reellement
sa dependance Redis, et un endpoint /metrics au format texte Prometheus.
"""
import os
import time

import redis
from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

APP_VERSION = os.environ.get("APP_VERSION", "0.0.0")
COMMIT_SHA = os.environ.get("COMMIT_SHA", "unknown")

app = Flask(__name__)

REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Nombre total de requetes HTTP recues",
    ["endpoint", "code"],
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "Duree de traitement des requetes HTTP, en secondes",
    ["endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

BUILD_INFO = Gauge(
    "app_build_info",
    "Version et SHA du commit actuellement deploye (vaut toujours 1)",
    ["version", "commit_sha"],
)
BUILD_INFO.labels(version=APP_VERSION, commit_sha=COMMIT_SHA).set(1)


def get_redis_client():
    """Construit un client Redis a partir des variables d'environnement."""
    return redis.Redis(
        host=os.environ.get("REDIS_HOST", "localhost"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
    )


@app.before_request
def _start_timer():
    g.request_start = time.perf_counter()


@app.after_request
def _record_metrics(response):
    """Alimente le compteur et l'histogramme pour chaque requete servie."""
    endpoint = request.url_rule.rule if request.url_rule else "unmatched"
    started = getattr(g, "request_start", None)
    if started is not None:
        REQUEST_DURATION.labels(endpoint=endpoint).observe(
            time.perf_counter() - started
        )
    REQUESTS_TOTAL.labels(endpoint=endpoint, code=str(response.status_code)).inc()
    return response


@app.route("/health")
def health():
    """Healthcheck reel : verifie que Redis repond a un PING."""
    try:
        get_redis_client().ping()
    except Exception as exc:
        return jsonify(status="degraded", redis="unreachable", detail=str(exc)), 503
    return jsonify(status="ok", redis="ok"), 200


@app.route("/status")
def status():
    return jsonify(
        service="devops-eval",
        version=APP_VERSION,
        commit_sha=COMMIT_SHA,
    ), 200


@app.route("/visits")
def visits():
    """Compteur de visites persiste dans Redis."""
    count = get_redis_client().incr("visits")
    return jsonify(visits=count), 200


@app.route("/boom")
def boom():
    """Renvoie volontairement une 5xx, pour declencher l'alerte ErrorRate."""
    return jsonify(error="erreur simulee"), 500


@app.route("/slow")
def slow():
    """Repond lentement, pour declencher l'alerte de latence p95."""
    time.sleep(float(request.args.get("seconds", "1")))
    return jsonify(status="ok"), 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
