"""Tests for filtering audit events by agent identifier / agent_ref.

When an agent is synthetic or Kubernetes-based (e.g. ``agent-cardvault``),
it has no UUID in ``agent_registry``. Audit records (such as ``agent.stunned``)
store ``agent_id = NULL`` and ``agent_name = NULL`` in the database, preserving
the pod/workload reference inside ``detail['agent_ref']``.

These tests ensure that ``GET /api/audit?agent=agent-cardvault`` correctly
retrieves audit events for synthetic agents in both in-memory and database modes.
"""
from __future__ import annotations

import socket
import time
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

TENANT = "tenant-agent-ref-test"
SUBJECT = "agent-ref-test-actor"
SUBJECT_TENANTS = {SUBJECT: TENANT}


def _bearer(subject: str = SUBJECT) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


class _ReadyPool:
    async def close(self) -> None:
        pass


class _FakeProxy:
    def __init__(self) -> None:
        self.observation = api_compat._ClusterStunObservation(
            observed=True,
            outcome="stunned",
            namespace="fe-signalloom-agents",
            proxy_status=200,
            error=None,
        )

    async def __call__(self, agent_id: str) -> Any:
        return self.observation


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    monkeypatch.setattr(api_compat, "_perform_cluster_stun", _FakeProxy())

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    api_compat.reset_tenant_state(TENANT)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT)


def test_stunning_synthetic_agent_is_retrievable_by_agent_filter(client: TestClient) -> None:
    """Break/fix test: stunning a non-UUID agent like agent-cardvault must be returned
    when querying GET /api/audit?agent=agent-cardvault."""
    agent_id = "agent-cardvault"

    # 1. Stun the synthetic agent
    stun_resp = client.post(f"/api/agents/{agent_id}/stun", headers=_bearer())
    assert stun_resp.status_code == 200, stun_resp.text
    event_payload = stun_resp.json()["event"]
    assert event_payload["event_type"] == "agent.stunned"
    assert event_payload["detail"]["agent_ref"] == agent_id

    # 2. Query audit trail filtered by the synthetic agent ID
    audit_resp = client.get(f"/api/audit?agent={agent_id}", headers=_bearer())
    assert audit_resp.status_code == 200, audit_resp.text
    events = audit_resp.json()["events"]

    matching_stuns = [
        e for e in events
        if e["event_type"] == "agent.stunned" and e.get("detail", {}).get("agent_ref") == agent_id
    ]
    assert len(matching_stuns) == 1
    assert matching_stuns[0]["actor"] == SUBJECT


def test_audit_filter_by_agent_does_not_leak_unrelated_synthetic_agents(client: TestClient) -> None:
    """Filtering by agent-cardvault must not return events for another synthetic agent."""
    client.post("/api/agents/agent-cardvault/stun", headers=_bearer())
    client.post("/api/agents/agent-other/stun", headers=_bearer())

    # Query for agent-cardvault only
    resp = client.get("/api/audit?agent=agent-cardvault", headers=_bearer())
    assert resp.status_code == 200
    events = resp.json()["events"]

    assert all(
        e.get("detail", {}).get("agent_ref") == "agent-cardvault"
        or (e.get("agent_name") and "cardvault" in e["agent_name"].lower())
        for e in events
    )
    assert not any(
        e.get("detail", {}).get("agent_ref") == "agent-other"
        for e in events
    )


def test_sql_query_construction_for_synthetic_agent(monkeypatch: pytest.MonkeyPatch, client: TestClient) -> None:
    """Ensure the SQL WHERE clause queries both agent_name and detail->>'agent_ref' when DB pool is active."""
    captured_queries: list[tuple[str, tuple[Any, ...]]] = []

    class _MockDBPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any]:
            captured_queries.append((query, params))
            return {"total": 0}

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            captured_queries.append((query, params))
            return []

    mock_pool = _MockDBPool()

    async def _mock_get_pool() -> Any:
        return mock_pool

    monkeypatch.setattr(api_compat, "_get_pool", _mock_get_pool)

    resp = client.get("/api/audit?agent=agent-cardvault", headers=_bearer())
    assert resp.status_code == 200

    assert len(captured_queries) >= 1
    count_query, count_params = captured_queries[0]

    # Verify SQL query conditions
    assert "agent_name ILIKE $2 OR detail->>'agent_ref' = $3" in count_query
    assert count_params[0] == TENANT
    assert count_params[1] == "%agent-cardvault%"
    assert count_params[2] == "agent-cardvault"
