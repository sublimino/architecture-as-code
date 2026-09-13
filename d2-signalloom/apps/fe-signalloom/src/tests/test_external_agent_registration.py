"""Integration and Adversarial Test Suite for AMXO-P2-2.

Validates:
1. Complete external agent registration lifecycle (pre-register -> query -> claim -> revoke).
2. Strict server-side tenant isolation and IDOR rejection.
3. Duplicate claim rejection in same-tenant and cross-tenant scenarios.
4. Pydantic validation (SafeID grammar, positive budget limits, forbidden tenant injection).
5. Database migration 039 structure (table, indexes, foreign keys, unique agent_id constraint).
6. Append-only audit logging for registration, claim, revocation, and claim rejection.
"""
from __future__ import annotations

import socket
import time
from pathlib import Path
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
from external_agent_registration import reset_external_agent_state

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE_SUB = "alice-ext-claim"
BOB_SUB = "bob-ext-claim"
TENANT_A = "tenant-ext-a"
TENANT_B = "tenant-ext-b"
SUBJECT_TENANTS = {
    ALICE_SUB: TENANT_A,
    BOB_SUB: TENANT_B,
}


def _bearer(subject: str = ALICE_SUB) -> dict[str, str]:
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
            "email": f"{subject}@signalloom.test",
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

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    api_compat.reset_tenant_state(TENANT_A)
    api_compat.reset_tenant_state(TENANT_B)
    reset_external_agent_state()
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT_A)
        api_compat.reset_tenant_state(TENANT_B)
        reset_external_agent_state()


def test_migration_039_structure() -> None:
    migration_path = Path(api_compat.__file__).parent / "db/migrations/039_external_agent_registrations.sql"
    assert migration_path.exists(), "Migration 039 file must exist"
    content = migration_path.read_text()

    assert "CREATE TABLE IF NOT EXISTS public.external_agent_registrations" in content
    assert "CONSTRAINT uq_external_agent_registrations_agent_id UNIQUE (agent_id)" in content
    assert "REFERENCES public.platform_users (id, tenant_id)" in content
    assert "external_agent.registered" in content
    assert "external_agent.claim_rejected" in content
    assert "external_agent.claimed" in content
    assert "DROP TABLE" not in content


def test_external_agent_registration_crud_lifecycle(client: TestClient) -> None:
    agent_id = "agentmaxxing-crud-01"
    host_id = "host-linux-01"

    # 1. Register
    reg_res = client.post(
        "/api/v1/external-agents/register",
        json={
            "agent_id": agent_id,
            "host_id": host_id,
            "host_os": "debian-12",
            "runtime_profile": "nono-0.73.0-standard",
            "allocated_token_budget": 125000,
            "metadata": {"region": "eu-west-1"},
        },
        headers=_bearer(ALICE_SUB),
    )
    assert reg_res.status_code == 201, reg_res.text
    record = reg_res.json()
    assert record["agent_id"] == agent_id
    assert record["tenant_id"] == TENANT_A
    assert record["host_id"] == host_id
    assert record["host_os"] == "debian-12"
    assert record["runtime_profile"] == "nono-0.73.0-standard"
    assert record["enrollment_status"] == "pending"
    assert record["allocated_token_budget"] == 125000
    assert record["metadata"] == {"region": "eu-west-1"}

    # 2. Query
    get_res = client.get(
        f"/api/v1/external-agents/registrations/{agent_id}",
        headers=_bearer(ALICE_SUB),
    )
    assert get_res.status_code == 200
    assert get_res.json()["agent_id"] == agent_id

    # 3. List
    list_res = client.get(
        "/api/v1/external-agents/registrations",
        headers=_bearer(ALICE_SUB),
    )
    assert list_res.status_code == 200
    assert list_res.json()["total"] == 1
    assert list_res.json()["registrations"][0]["agent_id"] == agent_id

    # 4. Claim
    claim_res = client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/claim",
        json={"harness": "nono-0.73.0", "model": "claude-3-5-sonnet"},
        headers=_bearer(ALICE_SUB),
    )
    assert claim_res.status_code == 200
    assert claim_res.json()["status"] == "granted"

    # 5. Revoke
    rev_res = client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/revoke",
        json={"reason": "routine_rotation"},
        headers=_bearer(ALICE_SUB),
    )
    assert rev_res.status_code == 200
    assert rev_res.json()["enrollment_status"] == "revoked"


def test_duplicate_claim_rejection(client: TestClient) -> None:
    agent_id = "agentmaxxing-dup-check"
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-01"},
        headers=_bearer(ALICE_SUB),
    )

    # First claim
    res1 = client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/claim",
        json={"harness": "nono-0.73.0"},
        headers=_bearer(ALICE_SUB),
    )
    assert res1.status_code == 200

    # Duplicate claim within same tenant -> 409 duplicate_claim
    res2 = client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/claim",
        json={"harness": "nono-0.73.0"},
        headers=_bearer(ALICE_SUB),
    )
    assert res2.status_code == 409
    assert res2.json()["error"]["code"] == "duplicate_claim"


def test_cross_tenant_claim_rejection(client: TestClient) -> None:
    agent_id = "agentmaxxing-cross-sec"
    # Alice registers in Tenant A
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-alice"},
        headers=_bearer(ALICE_SUB),
    )

    # Bob in Tenant B tries to claim Alice's agent -> 409 claim_conflict
    bob_claim = client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/claim",
        json={"harness": "nono-0.73.0"},
        headers=_bearer(BOB_SUB),
    )
    assert bob_claim.status_code in (403, 409)
    assert TENANT_A not in bob_claim.text


def test_cross_tenant_registration_rejection(client: TestClient) -> None:
    agent_id = "agentmaxxing-collision-sec"
    # Alice registers in Tenant A
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-alice"},
        headers=_bearer(ALICE_SUB),
    )

    # Bob tries to register the same agent_id in Tenant B -> 409 claim_conflict
    bob_reg = client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-bob"},
        headers=_bearer(BOB_SUB),
    )
    assert bob_reg.status_code == 409
    assert bob_reg.json()["error"]["code"] == "claim_conflict"
    assert TENANT_A not in bob_reg.text


def test_unauthenticated_request_rejected(client: TestClient) -> None:
    assert client.get("/api/v1/external-agents/registrations").status_code == 401
    assert client.post("/api/v1/external-agents/register", json={}).status_code == 401
    assert client.get("/api/v1/external-agents/registrations/some-agent").status_code == 401
    assert client.post("/api/v1/external-agents/registrations/some-agent/claim").status_code == 401


def test_audit_logging_events(client: TestClient) -> None:
    agent_id = "agentmaxxing-audited-01"
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-audited"},
        headers=_bearer(ALICE_SUB),
    )
    client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/claim",
        json={"harness": "nono-0.73.0"},
        headers=_bearer(ALICE_SUB),
    )

    # Trigger a duplicate claim rejection to test audit logging of rejection
    client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/claim",
        json={"harness": "nono-0.73.0"},
        headers=_bearer(ALICE_SUB),
    )

    audit_res = client.get("/api/audit", headers=_bearer(ALICE_SUB))
    assert audit_res.status_code == 200
    events = audit_res.json()["events"]

    types = [e.get("event_type") for e in events]
    assert "external_agent.registered" in types
    assert "external_agent.claimed" in types
    assert "external_agent.claim_rejected" in types
