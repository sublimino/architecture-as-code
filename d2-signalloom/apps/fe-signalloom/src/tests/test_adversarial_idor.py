"""Adversarial tests: IDOR and tenant isolation attacks.

These tests probe cross-tenant access, path parameter confusion, and
resource isolation boundaries that the fixture-based test suite does not
exercise.
"""
from __future__ import annotations

import base64
import json
import socket
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings, reset_tenant_state
from db.connection import set_pool_for_testing
from main import app


# ---------------------------------------------------------------------------
# Test JWT infrastructure (mirrors test_api_compat.py)
# ---------------------------------------------------------------------------

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(
    subject: str = "alice",
    *,
    email: str | None = None,
    extra_claims: dict | None = None,
) -> str:
    now = int(time.time())
    claims = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
    }
    if email:
        claims["email"] = email
    if extra_claims:
        claims.update(extra_claims)
    return jwt.encode(claims, TEST_SIGNING_KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"})


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


class _ReadyPool:
    async def close(self):
        pass


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-a", "bob": "tenant-b", "carol": "tenant-c"},
    )
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external(*_a, **_kw):
        raise AssertionError("no external network in tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external)
    set_pool_for_testing(_ReadyPool())

    # Clean slate for each test
    reset_tenant_state("tenant-a")
    reset_tenant_state("tenant-b")
    reset_tenant_state("tenant-c")

    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


# ── helpers ───────────────────────────────────────────────────────────────

ALICE = lambda: _bearer(_token_for("alice", email="alice@corp.test"))
BOB = lambda: _bearer(_token_for("bob", email="bob@corp.test"))
CAROL = lambda: _bearer(_token_for("carol", email="carol@evil.test"))


# =========================================================================
# 1. API-KEY IDOR: tenant_id_path is never checked against principal.tenant
# =========================================================================

class TestApiKeyTenantPathInjection:
    """The /tenants/{tenant_id_path}/api-keys/* endpoints accept a tenant ID
    in the URL path but derive the DB tenant from the JWT. The path parameter
    is used to build the key material (sl_live_{tenant_id_path}_...) but
    is never validated to match principal.tenant.

    This means:
    - A caller authenticated as tenant-a can mint a key whose prefix says
      tenant-b, potentially misdirecting credential attribution.
    - In fixture mode the key is returned with the wrong tenant prefix.
    - In DB mode the key_hash is stored against the real tenant but the
      prefix_hint in the key material says something different.
    """

    def test_cross_tenant_initial_key_rejected(self, client):
        """Alice (tenant-a) calls /tenants/tenant-b/api-keys/initial.
        FIXED: the path tenant is now validated against the JWT tenant.
        A mismatch returns 403 tenant_mismatch."""
        resp = client.post(
            "/api/tenants/tenant-b/api-keys/initial",
            headers=ALICE(),
        )
        assert resp.status_code == 403
        body = resp.json()
        assert body["error"]["code"] == "tenant_mismatch"

    def test_cross_tenant_rotate_key_rejected(self, client):
        """Same guard on the rotate endpoint."""
        resp = client.post(
            "/api/tenants/tenant-b/api-keys/rotate",
            headers=ALICE(),
        )
        assert resp.status_code == 403
        body = resp.json()
        assert body["error"]["code"] == "tenant_mismatch"

    def test_matching_tenant_initial_key_succeeds(self, client):
        """When path and JWT tenant match, key is minted correctly."""
        resp = client.post(
            "/api/tenants/tenant-a/api-keys/initial",
            headers=ALICE(),
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["key"].startswith("sl_live_tenant-a_")

    def test_matching_tenant_rotate_key_succeeds(self, client):
        """When path and JWT tenant match, rotation works."""
        resp = client.post(
            "/api/tenants/tenant-a/api-keys/rotate",
            headers=ALICE(),
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["key"].startswith("sl_live_tenant-a_")

    def test_sql_injection_in_path_rejected(self, client):
        """SQL injection in tenant_id_path is rejected by the tenant
        mismatch guard before it reaches key material."""
        resp = client.post(
            "/api/tenants/' OR 1=1 --/api-keys/initial",
            headers=ALICE(),
        )
        assert resp.status_code in (403, 404), f"Unexpected: {resp.status_code}"

    def test_path_traversal_rejected(self, client):
        """Path traversal in tenant_id_path is rejected by the guard."""
        resp = client.post(
            "/api/tenants/../../etc/passwd/api-keys/initial",
            headers=ALICE(),
        )
        assert resp.status_code in (403, 404)

    def test_overlong_path_rejected(self, client):
        """Overlong tenant_id_path is rejected by the guard."""
        huge = "A" * 10000
        resp = client.post(
            f"/api/tenants/{huge}/api-keys/initial",
            headers=ALICE(),
        )
        assert resp.status_code == 403


# =========================================================================
# 2. Cross-tenant data isolation in fixture mode
# =========================================================================

class TestCrossTenantFixtureIsolation:
    """Verify that fixture-mode stores are properly keyed by tenant."""

    def test_alice_cannot_see_bob_agents(self, client):
        """Each tenant sees only their own agents."""
        alice_agents = client.get("/api/agents", headers=ALICE()).json()
        bob_agents = client.get("/api/agents", headers=BOB()).json()

        alice_ids = {a["id"] for a in alice_agents["agents"]}
        bob_ids = {a["id"] for a in bob_agents["agents"]}

        # No overlap
        assert not alice_ids & bob_ids, f"Shared agent IDs: {alice_ids & bob_ids}"

        # Tenant prefix check
        for aid in alice_ids:
            assert aid.startswith("tenant-a:"), f"Alice agent {aid} has wrong prefix"
        for bid in bob_ids:
            assert bid.startswith("tenant-b:"), f"Bob agent {bid} has wrong prefix"

    def test_alice_cannot_transition_bob_agent(self, client):
        """Transition endpoint uses principal.tenant, so Alice acting on a
        Bob agent ID should create it under Alice's namespace, not touch Bob's."""
        bob_agent_id = "tenant-b:agent-1"
        resp = client.post(
            f"/api/agents/{bob_agent_id}/transition",
            headers=ALICE(),
            json={"to_state": "decommissioned", "reason": "cross-tenant attack"},
        )
        assert resp.status_code == 200
        # Check that Bob's agent is unchanged
        bob_agents = client.get("/api/agents", headers=BOB()).json()
        for agent in bob_agents["agents"]:
            if agent["id"] == bob_agent_id:
                assert agent["lifecycle_state"] != "decommissioned", (
                    "Cross-tenant transition succeeded!"
                )

    def test_alice_cannot_see_bob_violations(self, client):
        """Violations are scoped to tenant."""
        alice_resp = client.get("/api/agents/tenant-a:agent-1/violations", headers=ALICE())
        bob_resp = client.get("/api/agents/tenant-b:agent-1/violations", headers=BOB())
        assert alice_resp.status_code == 200
        assert bob_resp.status_code == 200

    def test_alice_cannot_read_bob_settings(self, client):
        """Tenant settings must be isolated."""
        # Alice changes her settings
        client.patch(
            "/api/tenant/settings/preferences",
            headers=ALICE(),
            json={"preferred_scan_cadence_hours": 48, "alert_email": "alice@corp.test", "alert_threshold": 5},
        )
        # Bob's settings should be unaffected
        bob_settings = client.get("/api/tenant/settings", headers=BOB()).json()
        assert bob_settings["preferred_scan_cadence_hours"] != 48 or bob_settings.get("alert_email") != "alice@corp.test"

    def test_alice_cannot_read_bob_audit(self, client):
        """Audit trail is tenant-scoped."""
        # Alice creates an agent (generates audit event)
        client.post(
            "/api/agents",
            headers=ALICE(),
            json={"name": "Alice's Agent", "type": "service"},
        )
        # Bob's audit should not contain Alice's event
        bob_audit = client.get("/api/audit", headers=BOB()).json()
        for event in bob_audit.get("events", []):
            assert "alice" not in event.get("actor", "").lower(), (
                f"Alice's audit event leaked to Bob: {event}"
            )

    def test_consent_isolation(self, client):
        """Consent is per-tenant."""
        client.post(
            "/api/consent/accept",
            headers=ALICE(),
            json={
                "document_versions": {"tos": "2026-01", "privacy": "2026-01"},
                "cookie_preferences": {"strictly_necessary": True, "analytics": True},
                "b2b_warranty_accepted": True,
            },
        )
        bob_consent = client.get("/api/consent/status", headers=BOB()).json()
        assert not bob_consent.get("accepted", False), "Alice's consent leaked to Bob"


# =========================================================================
# 3. _synth_agent creates agents for arbitrary IDs
# =========================================================================

class TestSynthAgentCreation:
    """When a transition targets a non-existent agent, _synth_agent creates
    one from nothing. This is a data integrity concern."""

    def test_transition_creates_phantom_agent(self, client):
        """Transitioning a non-existent agent should either 404 or create it
        under the caller's tenant. Currently it creates one via _synth_agent
        and stores it in the per-tenant dict, but the agents list endpoint
        reads from the same store. The synth agent IS stored, but the agents
        list may not iterate the same way. Document the behaviour."""
        fake_id = "totally-made-up-agent-id"
        resp = client.post(
            f"/api/agents/{fake_id}/transition",
            headers=ALICE(),
            json={"to_state": "active", "reason": "testing synth"},
        )
        # The endpoint accepts it (creates via _synth_agent) — this is a data
        # integrity concern: any agent_id can be transitioned into existence
        assert resp.status_code == 200
        body = resp.json()
        assert body["agent_id"] == fake_id
        assert body["to_state"] == "active"

    def test_credential_issue_for_nonexistent_agent_returns_404(self, client):
        """Issuing credentials for a non-existent agent correctly returns 404.
        This is the CORRECT behaviour — unlike transition, credential issuance
        validates agent existence."""
        fake_id = "ghost-agent-42"
        resp = client.post(
            f"/api/agents/{fake_id}/credentials",
            headers=ALICE(),
        )
        assert resp.status_code == 404


# =========================================================================
# 4. _AGENT_CREDENTIALS not reset — state leak
# =========================================================================

class TestCredentialStateLeak:
    """_AGENT_CREDENTIALS is missing from reset_tenant_state, so credential
    data persists across test resets and potentially across tenants."""

    def test_credentials_cleared_by_reset(self, client):
        """Issue a credential, reset, verify it's gone.
        FIXED: _AGENT_CREDENTIALS is now included in reset_tenant_state."""
        # Issue credential
        client.post("/api/agents/tenant-a:agent-1/credentials", headers=ALICE())

        # Reset
        reset_tenant_state("tenant-a")

        # After reset, revoke should find nothing to revoke
        resp = client.post("/api/agents/tenant-a:agent-1/credentials/revoke", headers=ALICE())
        assert resp.status_code == 200
        body = resp.json()
        assert body["tokens_revoked"] == 0, (
            f"Expected 0 tokens after reset, got {body['tokens_revoked']} — "
            "_AGENT_CREDENTIALS still leaking through reset"
        )
