"""The connectors store against a real PostgreSQL (Tier 2).

Skipped unless ``DATABASE_URL`` is set, like ``test_migrations_integration.py``.
Every migration is applied to a scratch database that is dropped afterwards;
the API then runs against it exactly as deployed, so the SQL itself (tenant
filters, upserts, JSONB and TIMESTAMPTZ round trips) is what is under test,
not a fake's reading of it.
"""
from __future__ import annotations

import asyncio
import os
import uuid
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import httpx
import pytest
import respx

from db.migrate import apply_migrations
from tests.test_connectors_live_honesty import ANTHROPIC, _token
from tests.test_connectors_persistence import SECRET, _client, _create, _key_file, _listed

DATABASE_URL = os.environ.get("DATABASE_URL")

pytestmark = pytest.mark.skipif(DATABASE_URL is None, reason="DATABASE_URL not set -- needs a live Postgres")


class _PerCallPool:
    """asyncpg connections opened per call, so the pool is not bound to one event loop.

    TestClient runs the app on its own loop; a real ``asyncpg.Pool`` created
    elsewhere could not be used from it.
    """

    def __init__(self, dsn: str) -> None:
        self.dsn = dsn

    @asynccontextmanager
    async def acquire(self):
        conn = await asyncpg.connect(self.dsn)
        try:
            yield conn
        finally:
            await conn.close()

    async def execute(self, sql: str, *args: Any) -> str:
        async with self.acquire() as conn:
            return await conn.execute(sql, *args)

    async def fetch(self, sql: str, *args: Any) -> list[Any]:
        async with self.acquire() as conn:
            return await conn.fetch(sql, *args)

    async def fetchrow(self, sql: str, *args: Any) -> Any:
        async with self.acquire() as conn:
            return await conn.fetchrow(sql, *args)

    async def fetchval(self, sql: str, *args: Any) -> Any:
        async with self.acquire() as conn:
            return await conn.fetchval(sql, *args)

    async def close(self) -> None:
        pass


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


@pytest.fixture
def pg():
    name = f"signalloom_conntest_{uuid.uuid4().hex[:12]}"

    async def _admin(sql: str, *args: Any) -> None:
        conn = await asyncpg.connect(DATABASE_URL)
        try:
            await conn.execute(sql, *args)
        finally:
            await conn.close()

    async def _migrate(dsn: str) -> None:
        pool = await asyncpg.create_pool(dsn, min_size=1, max_size=1)
        try:
            await apply_migrations(pool)
        finally:
            await pool.close()

    asyncio.run(_admin(f'CREATE DATABASE "{name}"'))
    dsn = _with_database(DATABASE_URL, name)
    try:
        asyncio.run(_migrate(dsn))
        yield _PerCallPool(dsn)
    finally:
        asyncio.run(_admin("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1", name))
        asyncio.run(_admin(f'DROP DATABASE IF EXISTS "{name}"'))


def _rows(pool: _PerCallPool, sql: str, *args: Any) -> list[Any]:
    return asyncio.run(pool.fetch(sql, *args))


def test_postgres_fresh_tenant_is_empty_and_a_connector_survives_a_restart(monkeypatch, tmp_path, pg):
    key = _key_file(tmp_path)
    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [{"id": "a1", "name": "One"}]}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        probe = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": [{"id": "m1"}]}))
        with _client(monkeypatch, pg, key) as client:
            assert _listed(client, "alice") == []
            conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
            scan = client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()
            assert scan["status"] == "success"

        with _client(monkeypatch, pg, key) as client:
            (row,) = _listed(client, "alice")
            assert (row["connector_id"], row["status"], row["last_scan_at"]) == (conn_id, "connected", scan["synced_at"])
            assert row["last_tested_at"] is None and row["credential_expires_at"] is None
            assert client.get("/api/v1/connectors/claude/logs", headers=_token("alice")).json()["records_scanned"] == {
                "agents": 1, "sessions": 0, "models": 1, "environments": None, "tools": None}
            before = len(probe.calls)
            assert client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()["valid"] is True
            assert [c.request.headers["x-api-key"] for c in probe.calls[before:]] == [SECRET]


def test_postgres_tenants_are_isolated_and_credentials_live_in_openbao(monkeypatch, tmp_path, pg):
    kv = _key_file(tmp_path)
    with _client(monkeypatch, pg, kv) as client:
        conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
        assert _listed(client, "bob") == []
        assert client.post(f"/api/v1/connectors/{conn_id}/toggle", headers=_token("bob"), json={"enabled": False}).status_code == 404
        assert client.delete(f"/api/v1/connectors/{conn_id}", headers=_token("bob")).status_code == 404
        bob_id = _create(client, "bob", "claude", {"api_key": "sk-ant-bob"})

        rows = {r["tenant_id"]: r for r in _rows(pg, "SELECT * FROM public.tenant_connectors")}
        assert set(rows) == {"tenant-a", "tenant-b"}
        assert rows["tenant-a"]["status"] == "connected"
        # Postgres holds the reference only; the value is in OpenBao (SA-TODO-003).
        path = f"signalloom/tenants/tenant-a/connectors/{conn_id}"
        assert (rows["tenant-a"]["credentials_ref"], rows["tenant-a"]["credentials_version"]) == (path, 1)
        assert rows["tenant-a"]["credentials_ciphertext"] is None
        assert SECRET not in repr(rows)
        assert kv.secrets[path] == [{"api_key": SECRET}]
        assert rows["tenant-b"]["credentials_ref"] == f"signalloom/tenants/tenant-b/connectors/{bob_id}"
        # Migration 078: a reference and a ciphertext can never share a row.
        with pytest.raises(Exception, match="credentials_one_store"):
            _rows(pg, "UPDATE public.tenant_connectors SET credentials_ciphertext = 'vault:v1:AAAA' "
                      "WHERE tenant_id = 'tenant-a'")

        # Disconnect deletes the credential and the scan result.
        assert client.delete(f"/api/v1/connectors/{conn_id}", headers=_token("alice")).status_code == 200
        (row,) = _rows(pg, "SELECT status, credentials_ref, credentials_ciphertext, last_scan_result "
                           "FROM public.tenant_connectors WHERE tenant_id = 'tenant-a'")
        assert tuple(row) == ("disconnected", None, None, None)
        assert path not in kv.secrets


def test_postgres_reconnect_keeps_the_id_and_merges_metadata(monkeypatch, tmp_path, pg):
    with _client(monkeypatch, pg, _key_file(tmp_path)) as client:
        first = client.post("/api/v1/connectors", headers=_token("alice"), json={
            "provider_id": "claude", "metadata": {"a": 1}, "credential_expires_at": "2031-05-05T00:00:00Z"}).json()
        second = client.post("/api/v1/connectors", headers=_token("alice"), json={
            "provider_id": "claude", "metadata": {"b": 2}, "credentials": {"api_key": SECRET}}).json()
        assert first["connector_id"] == second["connector_id"]
        (row,) = _listed(client, "alice")
        assert row["metadata"] == {"a": 1, "b": 2}
        assert row["credential_expires_at"] == "2031-05-05T00:00:00Z"
