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


# ---------------------------------------------------------------------------
# Class sweep: no invented model or provider on the database branches.
# ---------------------------------------------------------------------------

async def _row(dsn: str, sql: str, *args: Any) -> Any:
    conn = await asyncpg.connect(dsn)
    try:
        return await conn.fetchrow(sql, *args)
    finally:
        await conn.close()


def _registry(dsn: str, name: str) -> Any:
    return asyncio.run(_row(
        dsn, "SELECT model_provider, model_name FROM public.agent_registry WHERE tenant_id = $1 AND name = $2",
        TENANT, name))


def _claim_model(dsn: str, pod_name: str) -> Any:
    row = asyncio.run(_row(
        dsn, "SELECT model FROM public.agent_claims WHERE tenant_id = $1 AND pod_name = $2", TENANT, pod_name))
    return row["model"] if row else None


def _as_operator(monkeypatch: pytest.MonkeyPatch) -> None:
    principal = api_compat.Principal(tenant=TENANT, subject=OPERATOR, email=f"{OPERATOR}@signalloom.test")
    app.dependency_overrides[api_compat.authenticated_principal] = lambda: principal
    monkeypatch.setattr(app, "dependency_overrides", app.dependency_overrides)


@pytest.fixture
def operator(scratch, monkeypatch: pytest.MonkeyPatch):
    _as_operator(monkeypatch)
    try:
        yield scratch
    finally:
        app.dependency_overrides.pop(api_compat.authenticated_principal, None)


def test_claims_record_no_invented_provider(scratch) -> None:
    client, workloads, dsn = scratch
    workloads.declare("kusari-agent", TENANT, model="deterministic")
    body = {"pod_name": "kusari-agent", "namespace": declared_workloads.NS,
            "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent"}
    assert client.post("/api/v1/agents/claim", json=body, headers=_bearer()).status_code == 200
    row = _registry(dsn, "kusari-agent")
    assert (row["model_provider"], row["model_name"]) == (None, "deterministic")


def test_discovery_claim_records_no_invented_provider(scratch) -> None:
    client, workloads, dsn = scratch
    workloads.declare("disc-agent", TENANT, model="deterministic")
    body = {"agent_id": "disc-agent", "namespace": declared_workloads.NS}
    assert client.post("/api/v1/discovery/claim", json=body, headers=_bearer()).status_code == 200
    row = _registry(dsn, "disc-agent")
    assert (row["model_provider"], row["model_name"]) == (None, "deterministic")


def test_external_claim_without_a_model_records_it_as_undeclared(operator) -> None:
    client, _workloads, dsn = operator
    reg = client.post("/api/v1/external-agents/registrations",
                      json={"agent_id": "ext-db-a", "host_id": "host-db-a"})
    assert reg.status_code == 201, reg.text
    res = client.post("/api/v1/external-agents/registrations/ext-db-a/claim", json={})
    assert res.status_code == 200, res.text
    row = _registry(dsn, "ext-db-a")
    assert (row["model_provider"], row["model_name"]) == (None, None)
    assert _claim_model(dsn, "ext-db-a") == "undeclared"


def test_external_claim_with_a_model_records_that_model(operator) -> None:
    client, _workloads, dsn = operator
    assert client.post("/api/v1/external-agents/registrations",
                       json={"agent_id": "ext-db-b", "host_id": "host-db-b"}).status_code == 201
    res = client.post("/api/v1/external-agents/registrations/ext-db-b/claim", json={"model": "llama-3.1-8b"})
    assert res.status_code == 200, res.text
    assert _registry(dsn, "ext-db-b")["model_name"] == "llama-3.1-8b"
    assert _claim_model(dsn, "ext-db-b") == "llama-3.1-8b"


def test_host_enrollment_records_no_invented_model_or_provider(operator) -> None:
    client, _workloads, dsn = operator
    agent, host = "agentmaxxing-linux-001", "amx-host-001"
    assert client.post("/api/v1/external-agents/registrations",
                       json={"agent_id": agent, "host_id": host}).status_code == 201
    tok = client.post(f"/v1/external-agents/registrations/{agent}/token", json={"ttl_seconds": 3600})
    assert tok.status_code == 200, tok.text
    enrol = {
        "schema_version": "1.0.0", "agent_id": agent, "host_id": host, "key_id": "host-key:001",
        "key_algorithm": "Ed25519", "public_key": "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg",
        "client_nonce": "bm9uY2UtMDAwMDAwMDAwMDAx", "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only", "credential_bootstrap": "pre-provisioned-out-of-band",
    }
    res = client.post("/v1/external-agents/enroll", json=enrol,
                      headers={"Authorization": f"Bearer {tok.json()['enrollment_token']}"})
    assert res.status_code == 201, res.text
    row = _registry(dsn, agent)
    assert (row["model_provider"], row["model_name"]) == (None, None)
    assert _claim_model(dsn, agent) == "undeclared"


def test_the_discovery_list_shows_undeclared_models_as_unknown(operator) -> None:
    client, _workloads, dsn = operator
    assert client.post("/api/v1/external-agents/registrations",
                       json={"agent_id": "ext-list", "host_id": "host-list"}).status_code == 201
    assert client.post("/api/v1/external-agents/registrations/ext-list/claim", json={}).status_code == 200
    res = client.get("/api/v1/discovery/workloads")
    assert res.status_code == 200, res.text
    models = {(w["source"], w["name"]): w["model"] for w in res.json()["workloads"]}
    # The registry row (model_name NULL) and the external registration (no
    # metadata model) are both listed with no model, not a guessed one.
    assert models[("local_k8s", "ext-list")] is None
    assert models[("external_services", "ext-list")] is None


def test_autoclaim_on_the_database_returns_its_claims(scratch) -> None:
    # Autoclaim on the database branch records and returns the workload's model.
    client, workloads, _dsn = scratch
    workloads.declare("auto-db", TENANT, model="deterministic")
    res = client.post("/api/v1/agents/autoclaim-discovered", headers=_bearer())
    assert res.status_code == 200, res.text
    assert {c["pod_name"]: c["model"] for c in res.json()["claimed"]} == {"auto-db": "deterministic"}
