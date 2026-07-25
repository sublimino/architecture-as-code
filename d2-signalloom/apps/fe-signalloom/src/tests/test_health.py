from fastapi.testclient import TestClient

from db.connection import set_pool_for_testing
from main import app


class ReadyPool:
    async def fetchval(self, query):
        assert query == "SELECT 1"
        return 1

    async def close(self):
        pass


class FailingPool:
    async def fetchval(self, query):
        raise RuntimeError("database unavailable")

    async def close(self):
        pass


class FailingRedis:
    async def ping(self):
        raise RuntimeError("redis unavailable")


def test_health_is_preserved_and_livez_has_no_dependency():
    set_pool_for_testing(None)
    with TestClient(app, raise_server_exceptions=False) as client:
        assert client.get("/health").json() == {"status": "ok"}
        assert client.get("/livez").json() == {"status": "live"}


def test_readyz_requires_postgresql_but_tolerates_redis_degradation():
    set_pool_for_testing(ReadyPool())
    with TestClient(app, raise_server_exceptions=False) as client:
        client.app.state.redis = FailingRedis()
        response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready", "postgresql": "ready", "redis": "degraded"}


def test_readyz_returns_503_for_unusable_postgresql():
    set_pool_for_testing(FailingPool())
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/readyz")
    assert response.status_code == 503
    assert response.json()["postgresql"] == "unavailable"
