"""Tests d'integration : ils utilisent un vrai serveur Redis.

En local : `docker compose up -d redis` avant de lancer pytest.
En CI : le service `redis` declare dans le job `test` du workflow.
"""
import pytest

from app import app, get_redis_client


@pytest.fixture(autouse=True)
def clean_redis():
    """Vide la base Redis avant chaque test.

    Echoue volontairement si Redis est injoignable : le service doit etre
    reellement utilise, pas simplement declare.
    """
    client = get_redis_client()
    client.flushdb()
    yield client


@pytest.fixture
def client():
    return app.test_client()


def test_health_repond_200_quand_redis_est_joignable(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok", "redis": "ok"}


def test_status_expose_la_version_et_le_sha(client):
    response = client.get("/status")
    assert response.status_code == 200
    data = response.get_json()
    assert data["service"] == "devops-eval"
    assert "version" in data
    assert "commit_sha" in data


def test_visits_incremente_et_persiste_dans_redis(client, clean_redis):
    assert client.get("/visits").get_json()["visits"] == 1
    assert client.get("/visits").get_json()["visits"] == 2
    # verification directe cote Redis : la valeur y est bien stockee
    assert clean_redis.get("visits") == "2"


def test_boom_renvoie_une_500(client):
    response = client.get("/boom")
    assert response.status_code == 500
    assert response.get_json()["error"] == "erreur simulee"


def test_metrics_expose_les_trois_familles_de_metriques(client):
    client.get("/health")
    body = client.get("/metrics").get_data(as_text=True)
    assert "http_requests_total" in body
    assert "http_request_duration_seconds_bucket" in body
    assert "app_build_info" in body


def test_le_compteur_porte_les_labels_endpoint_et_code(client):
    client.get("/health")
    client.get("/boom")
    body = client.get("/metrics").get_data(as_text=True)
    assert 'endpoint="/health"' in body
    assert 'endpoint="/boom"' in body
    assert 'code="200"' in body
    assert 'code="500"' in body
