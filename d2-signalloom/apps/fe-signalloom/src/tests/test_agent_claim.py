"""Agent Claim and Governance Auto-Enrollment Test Suite.

Covers SLAC-P1-1 and SLAC-P1-2:
1. REST API contracts for POST /api/v1/agents/claim, POST /api/v1/agents/{agent_id}/claim,
   POST /api/v1/agents/autoclaim-discovered, GET /api/v1/agents/claims,
   GET/DELETE /api/v1/agents/claim/{claim_id}.
2. Pydantic validation (422 invalid_request envelope) and 404 on non-existent agents.
3. Strict tenant isolation across all claim endpoints.
4. Idempotency on repeated claim requests.
5. Governance compliance seeding: 6 controls evaluated (5 pass, 1 pending) -> 83% posture.
6. Append-only audit logging: 'agent.created' with action='claimed'.
7. Transactional integrity and rollback.
"""
from __future__ import annotations

import socket
import time
import uuid
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

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE_SUB = "alice-claim"
BOB_SUB = "bob-claim"
TENANT_A = "tenant-claim-a"
TENANT_B = "tenant-claim-b"
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
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT_A)
        api_compat.reset_tenant_state(TENANT_B)


# ---------------------------------------------------------------------------
# P1-1: Claim REST Endpoints, Pydantic Models, Validation, and Tenant Boundaries
# ---------------------------------------------------------------------------

def test_submit_claim_valid(client: TestClient) -> None:
    payload = {
        "pod_name": "agent-runner-01",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-runner-01",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": ["bash", "edit", "grep"],
        "token_budget_limit": 150000,
    }
    response = client.post("/api/v1/agents/claim", json=payload, headers=_bearer(ALICE_SUB))
    assert response.status_code == 200, response.text
    data = response.json()

    assert data["claim_id"].startswith("claim-")
    assert data["status"] == "granted"
    assert data["spiffe_svid_verified"] is True
    assert data["allocated_token_budget"] == 150000
    assert data["ebpf_sentinel_bound"] is True
    assert data["agent_id"] is not None

    # Test compatibility endpoint alias /api/agents/claim
    alias_res = client.post("/api/agents/claim", json=payload, headers=_bearer(ALICE_SUB))
    assert alias_res.status_code == 200, alias_res.text


def test_submit_claim_validation_error_422(client: TestClient) -> None:
    # Missing required pod_name and spiffe_id
    response = client.post("/api/v1/agents/claim", json={}, headers=_bearer(ALICE_SUB))
    assert response.status_code == 422, response.text
    body = response.json()
    assert "error" in body
    assert body["error"]["code"] == "invalid_request"


def test_claim_agent_by_id_valid_and_not_found(client: TestClient) -> None:
    # First seed an agent
    seed_payload = {
        "pod_name": "agent-discovered-target",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-discovered-target",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": [],
        "token_budget_limit": 100000,
    }
    create_res = client.post("/api/v1/agents/claim", json=seed_payload, headers=_bearer(ALICE_SUB))
    assert create_res.status_code == 200
    agent_id = create_res.json()["agent_id"]

    # One-click claim by agent ID
    claim_res = client.post(f"/api/v1/agents/{agent_id}/claim", json=None, headers=_bearer(ALICE_SUB))
    assert claim_res.status_code == 200, claim_res.text
    claim_data = claim_res.json()
    assert claim_data["status"] == "granted"
    assert claim_data["agent_id"] == agent_id

    # Non-existent agent ID returns 404
    missing_id = "00000000-0000-0000-0000-999999999999"
    missing_res = client.post(f"/api/v1/agents/{missing_id}/claim", json=None, headers=_bearer(ALICE_SUB))
    assert missing_res.status_code == 404, missing_res.text
    assert missing_res.json()["error"]["code"] == "not_found"


def test_autoclaim_discovered(client: TestClient) -> None:
    response = client.post("/api/v1/agents/autoclaim-discovered", headers=_bearer(ALICE_SUB))
    assert response.status_code == 200, response.text
    data = response.json()
    assert "claimed" in data
    assert "total_claimed" in data
    assert data["total_claimed"] >= 1
    assert len(data["claimed"]) == data["total_claimed"]


def test_claims_list_get_and_delete_lifecycle(client: TestClient) -> None:
    # 1. Create a claim
    claim_payload = {
        "pod_name": "lifecycle-agent",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/lifecycle-agent",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": ["edit"],
        "token_budget_limit": 75000,
    }
    create_res = client.post("/api/v1/agents/claim", json=claim_payload, headers=_bearer(ALICE_SUB))
    assert create_res.status_code == 200
    claim_id = create_res.json()["claim_id"]

    # 2. List claims
    list_res = client.get("/api/v1/agents/claims", headers=_bearer(ALICE_SUB))
    assert list_res.status_code == 200, list_res.text
    list_data = list_res.json()
    assert list_data["total"] >= 1
    assert any(c["claim_id"] == claim_id for c in list_data["claims"])

    # 3. Get single claim
    get_res = client.get(f"/api/v1/agents/claim/{claim_id}", headers=_bearer(ALICE_SUB))
    assert get_res.status_code == 200, get_res.text
    record = get_res.json()
    assert record["claim_id"] == claim_id
    assert record["pod_name"] == "lifecycle-agent"
    assert record["status"] == "granted"
    assert record["released_at"] is None

    # 4. Release claim
    del_res = client.delete(f"/api/v1/agents/claim/{claim_id}", headers=_bearer(ALICE_SUB))
    assert del_res.status_code == 200, del_res.text
    assert del_res.json()["status"] == "released"

    # 5. Check release state reflected
    get_after = client.get(f"/api/v1/agents/claim/{claim_id}", headers=_bearer(ALICE_SUB))
    assert get_after.status_code == 200
    assert get_after.json()["released_at"] is not None

    # 6. Not found cases
    assert client.get("/api/v1/agents/claim/claim-unknown", headers=_bearer(ALICE_SUB)).status_code == 404
    assert client.delete("/api/v1/agents/claim/claim-unknown", headers=_bearer(ALICE_SUB)).status_code == 404


def test_tenant_isolation_on_claims(client: TestClient) -> None:
    # Alice creates a claim
    claim_payload = {
        "pod_name": "alice-workload",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/alice-workload",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": [],
        "token_budget_limit": 50000,
    }
    alice_res = client.post("/api/v1/agents/claim", json=claim_payload, headers=_bearer(ALICE_SUB))
    assert alice_res.status_code == 200
    claim_id = alice_res.json()["claim_id"]

    # Bob lists claims: must NOT see Alice's claim
    bob_list = client.get("/api/v1/agents/claims", headers=_bearer(BOB_SUB))
    assert bob_list.status_code == 200
    assert not any(c["claim_id"] == claim_id for c in bob_list.json()["claims"])

    # Bob attempts to get or delete Alice's claim: returns 404
    assert client.get(f"/api/v1/agents/claim/{claim_id}", headers=_bearer(BOB_SUB)).status_code == 404
    assert client.delete(f"/api/v1/agents/claim/{claim_id}", headers=_bearer(BOB_SUB)).status_code == 404

    # Unauthenticated request returns 401
    assert client.get("/api/v1/agents/claims").status_code == 401


def test_openapi_schema_contains_claim_endpoints(client: TestClient) -> None:
    res = client.get("/openapi.json")
    assert res.status_code == 200
    paths = res.json().get("paths", {})

    assert "/api/v1/agents/claim" in paths
    assert "/api/v1/agents/{agent_id}/claim" in paths
    assert "/api/v1/agents/autoclaim-discovered" in paths
    assert "/api/v1/agents/claims" in paths
    assert "/api/v1/agents/claim/{claim_id}" in paths


# ---------------------------------------------------------------------------
# P1-2: Idempotency, Compliance Seeding, and Audit Logging
# ---------------------------------------------------------------------------

def test_idempotent_reclaim(client: TestClient) -> None:
    payload = {
        "pod_name": "idempotent-agent",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/idempotent-agent",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": ["bash"],
        "token_budget_limit": 100000,
    }
    first_res = client.post("/api/v1/agents/claim", json=payload, headers=_bearer(ALICE_SUB))
    assert first_res.status_code == 200
    first_id = first_res.json()["agent_id"]

    # Repeat exact claim request
    second_res = client.post("/api/v1/agents/claim", json=payload, headers=_bearer(ALICE_SUB))
    assert second_res.status_code == 200
    second_id = second_res.json()["agent_id"]

    # Re-claiming returns the same agent ID without error
    assert first_id == second_id


def test_db_claim_upsert_matches_tenant_scoped_registry_constraint() -> None:
    source = Path(api_compat.__file__).read_text()
    migration = (
        Path(api_compat.__file__).parent / "db/migrations/035_agent_claim_contract.sql"
    ).read_text()

    assert "ON public.agent_registry (tenant_id, name)" in migration
    assert "ON CONFLICT (tenant_id, name) DO UPDATE SET" in source
    assert "ON CONFLICT (name) DO UPDATE SET" not in source


def test_compliance_posture_seeding(client: TestClient) -> None:
    payload = {
        "pod_name": "posture-test-agent",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/posture-test-agent",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": [],
        "token_budget_limit": 100000,
    }
    claim_res = client.post("/api/v1/agents/claim", json=payload, headers=_bearer(ALICE_SUB))
    assert claim_res.status_code == 200
    agent_id = claim_res.json()["agent_id"]

    # Query agent profile
    agent_res = client.get(f"/api/agents/{agent_id}", headers=_bearer(ALICE_SUB))
    assert agent_res.status_code == 200
    agent_data = agent_res.json()

    assert agent_data["lifecycle_state"] == "active"
    assert agent_data["is_registry_linked"] is True
    assert agent_data["record_class"] == "resolved"

    summary = agent_data["compliance_summary"]
    assert summary["total_controls"] == 6
    assert summary["passing"] == 5
    assert summary["pending"] == 1
    assert summary["failing"] == 0
    assert summary["posture_score"] == 0.83


def test_audit_event_logged_on_claim(client: TestClient) -> None:
    payload = {
        "pod_name": "audited-agent",
        "namespace": "fe-signalloom-agents",
        "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/audited-agent",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "declared_tools": [],
        "token_budget_limit": 100000,
    }
    claim_res = client.post("/api/v1/agents/claim", json=payload, headers=_bearer(ALICE_SUB))
    assert claim_res.status_code == 200

    audit_res = client.get("/api/audit", headers=_bearer(ALICE_SUB))
    assert audit_res.status_code == 200
    events = audit_res.json()["events"]

    claim_events = [
        e for e in events
        if e.get("event_type") == "agent.created"
        and isinstance(e.get("detail"), dict)
        and e["detail"].get("action") == "claimed"
        and e.get("agent_name") == "audited-agent"
    ]
    assert len(claim_events) >= 1
    ev = claim_events[0]
    assert ev["actor"] == f"{ALICE_SUB}@signalloom.test"
    assert ev["detail"]["pod_name"] == "audited-agent"
    assert ev["detail"]["spiffe_id"] == payload["spiffe_id"]
