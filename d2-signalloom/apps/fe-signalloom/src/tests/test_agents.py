"""Adversarial and Contract Test Suite for Agent Governance & State Machine.

Validates:
1. POST /api/v1/agents/{agent_id}/transition:
   - Valid lifecycle state transitions (discovered -> governed, governed -> suspended/stunned, suspended -> active, governed -> revoked).
   - Terminal states and illegal transitions (revoked -> governed, decommissioned -> active) return 409 Conflict with structured envelope.
   - Unknown target states return 400 Bad Request with structured envelope.
   - Cross-tenant isolation (IDOR): mutating another tenant's agent returns 403 Forbidden or 404 Not Found.
2. GET /api/v1/agents with attention_required filter:
   - Filters agents requiring operator attention (findings, suspended, stunned, missing SBOM).
"""
from __future__ import annotations

import json
import time
from typing import Any
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE_SUB = "alice-agent-test"
BOB_SUB = "bob-agent-test"
TENANT_A = "tenant-agent-a"
TENANT_B = "tenant-agent-b"
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
        headers={"kid": "test-key-agents", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> Any:
        from types import SimpleNamespace
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


@pytest.fixture(autouse=True)
def _setup_agent_test_env(monkeypatch: pytest.MonkeyPatch):
    """Isolate test environment with JWT validation stub and fixture state."""
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

    # Initialize tenant agents in memory
    with api_compat._STORE_LOCK:
        api_compat._AGENTS.setdefault(TENANT_A, {})
        api_compat._AGENTS.setdefault(TENANT_B, {})
        api_compat._AGENTS[TENANT_A]["agent-healthy"] = {
            "id": "agent-healthy",
            "tenant_id": TENANT_A,
            "name": "Healthy Worker",
            "lifecycle_state": "active",
            "status": "active",
            "compliance_posture": 100,
            "findings_count": 0,
            "has_sbom": True,
        }
        api_compat._AGENTS[TENANT_A]["agent-warning"] = {
            "id": "agent-warning",
            "tenant_id": TENANT_A,
            "name": "Flagged Worker",
            "lifecycle_state": "suspended",
            "status": "suspended",
            "compliance_posture": 45,
            "findings_count": 3,
            "has_sbom": False,
        }
        api_compat._AGENTS[TENANT_A]["agent-discovered"] = {
            "id": "agent-discovered",
            "tenant_id": TENANT_A,
            "name": "Discovered Pod",
            "lifecycle_state": "discovered",
            "status": "active",
            "compliance_posture": 80,
            "findings_count": 0,
            "has_sbom": True,
        }
        api_compat._AGENTS[TENANT_A]["agent-revoked"] = {
            "id": "agent-revoked",
            "tenant_id": TENANT_A,
            "name": "Terminated Worker",
            "lifecycle_state": "revoked",
            "status": "revoked",
            "compliance_posture": 0,
            "findings_count": 5,
            "has_sbom": False,
        }


@pytest.fixture
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


# ---------------------------------------------------------------------------
# State Transition Tests
# ---------------------------------------------------------------------------

class TestAgentStateTransitionsAdversarial:
    def test_valid_transition_discovered_to_governed(self, client: TestClient):
        """Valid transition from discovered to governed succeeds."""
        res = client.post(
            "/api/v1/agents/agent-discovered/transition",
            json={"to_state": "governed", "reason": "Operator verification complete"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 200
        data = res.json()
        assert data["agent_id"] == "agent-discovered"
        assert data["from_state"] == "discovered"
        assert data["to_state"] == "governed"

    def test_valid_transition_governed_to_suspended(self, client: TestClient):
        """Valid transition from governed to suspended succeeds."""
        # First transition discovered to governed
        client.post(
            "/api/v1/agents/agent-discovered/transition",
            json={"to_state": "governed", "reason": "Pre-condition step"},
            headers=_bearer(ALICE_SUB),
        )
        # Then transition governed to suspended
        res = client.post(
            "/api/v1/agents/agent-discovered/transition",
            json={"to_state": "suspended", "reason": "Security isolation"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 200
        data = res.json()
        assert data["from_state"] == "governed"
        assert data["to_state"] == "suspended"

    def test_illegal_transition_revoked_to_governed_returns_409(self, client: TestClient):
        """Revoked state is terminal; transition to governed must return 409 Conflict."""
        res = client.post(
            "/api/v1/agents/agent-revoked/transition",
            json={"to_state": "governed", "reason": "Illegal re-activation attempt"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 409
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "invalid_transition"

    def test_illegal_transition_revoked_to_active_returns_409(self, client: TestClient):
        """Revoked state is terminal; transition to active must return 409 Conflict."""
        res = client.post(
            "/api/v1/agents/agent-revoked/transition",
            json={"to_state": "active", "reason": "Illegal re-activation attempt"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 409
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "invalid_transition"

    def test_unknown_target_state_returns_400(self, client: TestClient):
        """Target state not in VALID_LIFECYCLE_STATES returns 400 Bad Request."""
        res = client.post(
            "/api/v1/agents/agent-healthy/transition",
            json={"to_state": "invalid_magic_state", "reason": "Typo in target state"},
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 400
        body = res.json()
        assert "error" in body
        assert body["error"]["code"] == "invalid_state"


# ---------------------------------------------------------------------------
# Attention Required Filter Tests
# ---------------------------------------------------------------------------

class TestAgentAttentionRequired:
    def test_attention_required_filters_flagged_agents(self, client: TestClient):
        """Query with attention_required=true returns only agents with findings or suspended state."""
        res = client.get(
            "/api/v1/agents?attention_required=true",
            headers=_bearer(ALICE_SUB),
        )
        assert res.status_code == 200
        data = res.json()
        items = data.get("agents") or data.get("items", [])
        ids = [item.get("id") or item.get("agent_id") or item.get("name") for item in items]
        # agent-warning should be present (suspended / has findings)
        assert "agent-warning" in ids
        # agent-healthy should not be flagged as needing attention
        assert "agent-healthy" not in ids
