"""Tier 2: a re-claim records the workload's CURRENT model in agent_registry.

Both claim upserts into public.agent_registry used ``ON CONFLICT (tenant_id,
name) DO UPDATE`` without updating ``model_name``, so once a row existed (for
example the fabricated ``claude-3-5-sonnet`` the Kusari pilot carried) no
honest re-claim could correct it. These tests run the real endpoints against a
real PostgreSQL scratch database with every migration applied.

Skipped unless ``DATABASE_URL`` is set, matching the Tier 2 convention.
"""
from __future__ import annotations

import asyncio
import os
import time
import uuid
from types import SimpleNamespace
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import routers.discovery as discovery_router
from api_compat import settings
from db.connection import set_pool_for_testing
from db.migrate import apply_migrations
from main import app
from tests import declared_workloads

DATABASE_URL = os.environ.get("DATABASE_URL")
pytestmark = pytest.mark.skipif(
    DATABASE_URL is None, reason="DATABASE_URL not set -- Tier 2 needs a live Postgres"
)

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OPERATOR = "kusari-operator"
TENANT = "kusari"


def _bearer() -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {"iss": "https://issuer.test/dex", "aud": "signalloom-api", "iat": now, "nbf": now,
         "exp": now + 300, "azp": "signalloom-dashboard", "sub": OPERATOR,
         "email": f"{OPERATOR}@signalloom.test"},
        KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _JWK:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        return SimpleNamespace(key=KEY.public_key())


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


async def _admin(sql: str) -> None:
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        await conn.execute(sql)
    finally:
        await conn.close()


async def _migrate(dsn: str) -> None:
    pool = await asyncpg.create_pool(dsn, min_size=1, max_size=2)
    try:
        await apply_migrations(pool)
    finally:
        await pool.close()


async def _registry_model(dsn: str, name: str) -> list[str]:
    conn = await asyncpg.connect(dsn)
    try:
        rows = await conn.fetch(
            "SELECT model_name FROM public.agent_registry WHERE tenant_id = $1 AND name = $2", TENANT, name
        )
        return [r["model_name"] for r in rows]
    finally:
        await conn.close()


@pytest.fixture
def scratch(monkeypatch: pytest.MonkeyPatch):
    name = f"signalloom_claimtest_{uuid.uuid4().hex[:12]}"
    asyncio.run(_admin(f'CREATE DATABASE "{name}"'))
    dsn = _with_database(DATABASE_URL, name)
    try:
        asyncio.run(_migrate(dsn))
        monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
        monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
        monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
        monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
        monkeypatch.setattr(settings, "api_subject_tenants", {OPERATOR: TENANT})
        monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWK())

        # The pool is created lazily inside the app's own event loop.
        state: dict[str, Any] = {}

        async def _pool() -> Any:
            if "pool" not in state:
                state["pool"] = await asyncpg.create_pool(dsn, min_size=1, max_size=4)
            return state["pool"]

        monkeypatch.setattr(api_compat, "_get_pool", _pool)
        monkeypatch.setattr(discovery_router, "_get_pool", _pool)

        async def _no_spine(**_kwargs: Any) -> bool:
            return True

        monkeypatch.setattr(api_compat, "sync_claim_delegation_to_spine", _no_spine)
        workloads = declared_workloads.install(monkeypatch)
        set_pool_for_testing(SimpleNamespace(close=_noop_close))
        with TestClient(app, raise_server_exceptions=False) as client:
            yield client, workloads, dsn
            if "pool" in state:
                client.portal.call(state["pool"].close)
    finally:
        set_pool_for_testing(None)
        asyncio.run(_admin(
            f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '{name}'"
        ))
        asyncio.run(_admin(f'DROP DATABASE IF EXISTS "{name}"'))


async def _noop_close() -> None:
    return None


def test_agents_claim_reclaim_records_the_workloads_current_model(scratch) -> None:
    client, workloads, dsn = scratch
    workloads.declare("kusari-agent", TENANT, model="claude-3-5-sonnet")
    body = {"pod_name": "kusari-agent", "namespace": declared_workloads.NS,
            "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent"}
    first = client.post("/api/v1/agents/claim", json=body, headers=_bearer())
    assert first.status_code == 200, first.text
    assert asyncio.run(_registry_model(dsn, "kusari-agent")) == ["claude-3-5-sonnet"]

    # GitOps corrects the label; the honest re-claim must correct the record.
    workloads.declare("kusari-agent", TENANT, model="deterministic")
    second = client.post("/api/v1/agents/claim", json=body, headers=_bearer())
    assert second.status_code == 200, second.text
    assert asyncio.run(_registry_model(dsn, "kusari-agent")) == ["deterministic"]


def test_discovery_claim_reclaim_records_the_workloads_current_model(scratch) -> None:
    client, workloads, dsn = scratch
    workloads.declare("kusari-agent", TENANT, model="claude-3-5-sonnet")
    body = {"agent_id": "kusari-agent", "namespace": declared_workloads.NS}
    first = client.post("/api/v1/discovery/claim", json=body, headers=_bearer())
    assert first.status_code == 200, first.text
    assert asyncio.run(_registry_model(dsn, "kusari-agent")) == ["claude-3-5-sonnet"]

    workloads.declare("kusari-agent", TENANT, model="deterministic")
    second = client.post("/api/v1/discovery/claim", json=body, headers=_bearer())
    assert second.status_code == 200, second.text
    assert asyncio.run(_registry_model(dsn, "kusari-agent")) == ["deterministic"]
