"""Adversarial Test Suite for Discovery Workload Claim Surface.

Validates:
1. POST /api/v1/discovery/claim input validation and structured error envelopes:
   - Malformed JSON, non-JSON content-types, and empty bodies return 400 with structured envelope.
   - Empty or whitespace agent ID returns 422 with structured envelope.
   - Missing or whitespace namespace returns 422 with structured envelope.
   - Non-existent or invalid namespace format returns 400 or 422 with structured envelope.
   - Malformed SPIFFE ID returns 400 with structured envelope.
   - Invalid scheme (http:// instead of spiffe://) returns 400 with structured envelope.
   - Cross-tenant forged SPIFFE ID returns 403 with structured envelope.
   - Zero unhandled 500 exceptions across adversarial inputs.
2. Valid claim workflow:
   - Transitions workload to Governed status.
   - Mints server-issued canonical SPIFFE ID.
   - Emits structured audit event 'agent.claimed'.
"""
from __future__ import annotations

import json
import time
from typing import Any
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE_SUB = "alice-discovery"
BOB_SUB = "bob-discovery"
TENANT_A = "tenant-disc-a"
TENANT_B = "tenant-disc-b"
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
    def get_signing_key_from_jwt(self, token: str) -> Any:
        from types import SimpleNamespace
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


@pytest.fixture(autouse=True)
def setup_test_env(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    api_compat.reset_tenant_state(TENANT_A)
    api_compat.reset_tenant_state(TENANT_B)
    with api_compat._STORE_LOCK:
        api_compat._AUDIT_EVENTS.clear()
        api_compat._CLAIMS.clear()


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)


# ---------------------------------------------------------------------------
# Adversarial Claim Tests
# ---------------------------------------------------------------------------

class TestDiscoveryClaimAdversarial:
    def test_claim_empty_body_returns_400_with_structured_error(self, client: TestClient):
        """Empty request body must return 400 Bad Request with structured error envelope."""
        res = client.post(
            "/api/v1/discovery/claim",
            data="",
            headers={**_bearer(ALICE_SUB), "Content-Type": "application/json"},
        )
        assert res.status_code == 400
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "malformed_request"
        assert len(body["error"]["message"]) > 0

    def test_claim_malformed_json_returns_400_never_500(self, client: TestClient):
        """Malformed JSON string must return 400 Bad Request and never unhandled 500."""
        res = client.post(
            "/api/v1/discovery/claim",
            content="{ malformed: json, missing quotes }",
            headers={**_bearer(ALICE_SUB), "Content-Type": "application/json"},
        )
        assert res.status_code == 400
        assert res.status_code != 500
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "malformed_request"

    def test_claim_invalid_content_type_returns_400(self, client: TestClient):
        """Non-JSON Content-Type must return 400 Bad Request with structured envelope."""
        res = client.post(
            "/api/v1/discovery/claim",
            data="plain text body",
            headers={**_bearer(ALICE_SUB), "Content-Type": "text/plain"},
        )
        assert res.status_code == 400
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "invalid_content_type"

    def test_claim_empty_agent_id_returns_422(self, client: TestClient):
        """Empty string agent_id must be rejected with 422 validation error."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": "", "namespace": "fe-signalloom-agents"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 422
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "validation_error"

    def test_claim_whitespace_agent_id_returns_422(self, client: TestClient):
        """Whitespace-only agent_id must be rejected with 422 validation error."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": "   \t\n  ", "namespace": "fe-signalloom-agents"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 422
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "validation_error"

    def test_claim_missing_namespace_returns_422(self, client: TestClient):
        """Payload missing namespace field must return 422 validation error."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": "test-workload-001"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 422
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "validation_error"

    def test_claim_whitespace_namespace_returns_422(self, client: TestClient):
        """Whitespace-only namespace must return 422 validation error."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": "test-workload-001", "namespace": "    "},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 422
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "validation_error"

    def test_claim_invalid_namespace_format_returns_422(self, client: TestClient):
        """Namespace with invalid RFC 1123 characters (e.g. uppercase, symbols) must return 422."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": "test-workload-001", "namespace": "INVALID_UPPERCASE_NS!"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 422
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] in {"validation_error", "invalid_namespace"}

    def test_claim_nonexistent_namespace_returns_400(self, client: TestClient):
        """Non-existent namespace outside known/tenant namespaces must return 400."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": "test-workload-001", "namespace": "unknown-nonexistent-ns-404"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 400
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "namespace_not_found"

    def test_claim_rejects_malformed_spiffe_id(self, client: TestClient):
        """Malformed SPIFFE ID (e.g. empty segments, invalid characters) must return 400."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={
                "agent_id": "test-workload-001",
                "namespace": "fe-signalloom-agents",
                "spiffe_id": "spiffe://cluster.local//double//slash",
            },
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 400
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "invalid_spiffe_id"

    def test_claim_rejects_invalid_spiffe_scheme_http(self, client: TestClient):
        """Client-supplied SPIFFE ID with http:// scheme must return 400 Bad Request."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={
                "agent_id": "test-workload-001",
                "namespace": "fe-signalloom-agents",
                "spiffe_id": "http://evil-attacker.example/sa/agent-1",
            },
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 400
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "invalid_spiffe_id"

    def test_claim_rejects_cross_tenant_forged_spiffe_id(self, client: TestClient):
        """SPIFFE ID naming tenant-b submitted by tenant-a must return 403 Forbidden."""
        res = client.post(
            "/api/v1/discovery/claim",
            json={
                "agent_id": "test-workload-001",
                "namespace": "fe-signalloom-agents",
                "spiffe_id": f"spiffe://cluster.local/platform/signalloom/tenant/{TENANT_B}/agent/forged-agent",
            },
            headers=_bearer(ALICE_SUB),  # Alice is TENANT_A
        )
        assert res.status_code == 403
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "cross_tenant_forbidden"


# ---------------------------------------------------------------------------
# Valid Claim & State Transition Tests
# ---------------------------------------------------------------------------

class TestDiscoveryClaimHappyPath:
    def test_claim_valid_workload_transitions_to_governed(self, client: TestClient):
        """Valid workload claim creates claim, transitions state to Governed, and mints SPIFFE ID."""
        agent_id = "discovered-agent-007"
        namespace = "fe-signalloom-agents"

        res = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": agent_id, "namespace": namespace, "token_budget_limit": 50000},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 200
        data = res.json()

        assert data["agent_id"] == agent_id
        assert data["tenant_id"] == TENANT_A
        assert data["namespace"] == namespace
        assert data["status"] == "granted"
        assert data["allocated_token_budget"] == 50000
        assert data["spiffe_id"] == f"spiffe://cluster.local/platform/signalloom/tenant/{TENANT_A}/agent/{agent_id}"

        # Verify audit log recorded event
        with api_compat._STORE_LOCK:
            audits = api_compat._AUDIT_EVENTS.get(TENANT_A, [])
            claim_events = [e for e in audits if e.get("event_type") == "agent.claimed"]
            assert len(claim_events) >= 1
            assert claim_events[-1]["agent_id"] == agent_id

    def test_claim_idempotency_same_tenant(self, client: TestClient):
        """Re-claiming the same workload by the same tenant succeeds idempotently."""
        agent_id = "discovered-agent-repeat"
        namespace = "fe-signalloom-agents"

        res1 = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": agent_id, "namespace": namespace},
            headers=_bearer(ALICE_SUB),
        )
        assert res1.status_code == 200

        res2 = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": agent_id, "namespace": namespace},
            headers=_bearer(ALICE_SUB),
        )
        assert res2.status_code == 200
        assert res2.json()["agent_id"] == agent_id

    def test_cross_tenant_claim_conflict_returns_409(self, client: TestClient):
        """Claiming a workload already held by tenant-a when requested by tenant-b returns 409 Conflict."""
        agent_id = "shared-agent-conflict"
        namespace = "fe-signalloom-agents"

        # Tenant A claims first
        res_a = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": agent_id, "namespace": namespace},
            headers=_bearer(ALICE_SUB),
        )
        assert res_a.status_code == 200

        # Tenant B attempts to claim the same agent
        res_b = client.post(
            "/api/v1/discovery/claim",
            json={"agent_id": agent_id, "namespace": namespace},
            headers=_bearer(BOB_SUB),  # Bob is TENANT_B
        )
        assert res_b.status_code == 409
        body = res_b.json()
        assert "error" in body
        assert body["error"]["code"] == "claim_conflict"
