import asyncio
from contextlib import asynccontextmanager

import pytest
from fastapi.testclient import TestClient

from db import connection
from db.connection import close_db_pool, init_db_pool, set_pool_for_testing
from db.migrate import MigrationError
from main import app


class RecordingConnection:
    """Enough of asyncpg.Connection for the startup migration runner."""

    def __init__(self):
        self.statements = []

    async def execute(self, query, *args):
        self.statements.append(query)

    async def fetch(self, query, *args):
        self.statements.append(query)
        return []


class ReadyPool:
    def __init__(self):
        self.connection = RecordingConnection()

    async def fetchval(self, query):
        assert query == "SELECT 1"
        return 1

    @asynccontextmanager
    async def acquire(self):
        yield self.connection

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
    set_pool_for_testing(ReadyPool())
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


def test_startup_initialises_pool_from_database_url(monkeypatch):
    pool = ReadyPool()
    observed = {}

    async def create_pool(**kwargs):
        observed.update(kwargs)
        return pool

    set_pool_for_testing(None)
    monkeypatch.setenv("DATABASE_URL", "postgresql://portal:secret@postgresql/db")
    monkeypatch.setattr(connection.asyncpg, "create_pool", create_pool)
    asyncio.run(init_db_pool())

    assert connection.get_pool() is pool
    assert observed == {"dsn": "postgresql://portal:secret@postgresql/db"}
    # Startup migrates: the pool is not handed out until the schema is current.
    statements = pool.connection.statements
    assert any("pg_advisory_lock" in s for s in statements)
    assert any("CREATE TABLE IF NOT EXISTS public.schema_migrations" in s for s in statements)
    assert any("preferred_scan_cadence_hours" in s for s in statements)
    asyncio.run(close_db_pool())


def test_startup_aborts_when_a_migration_fails(monkeypatch):
    """A half-migrated schema must never end up serving traffic."""
    closed = []

    class FailingMigrationPool(ReadyPool):
        async def close(self):
            closed.append(True)

    pool = FailingMigrationPool()

    async def create_pool(**_kwargs):
        return pool

    async def boom(_pool, *_args, **_kwargs):
        raise MigrationError("migration 999_broken.sql failed: syntax error")

    set_pool_for_testing(None)
    monkeypatch.setenv("DATABASE_URL", "postgresql://portal:secret@postgresql/db")
    monkeypatch.setattr(connection.asyncpg, "create_pool", create_pool)
    monkeypatch.setattr(connection, "apply_migrations", boom)

    with pytest.raises(MigrationError, match="999_broken.sql"):
        asyncio.run(init_db_pool())

    assert closed == [True], "the pool must be released when startup aborts"
    with pytest.raises(RuntimeError, match="not initialised"):
        connection.get_pool()
