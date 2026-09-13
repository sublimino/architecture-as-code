"""Integration and Adversarial Test Suite for Host Enrollment and Revocation (AMXO-P3-3).

Validates:
1. Complete host enrollment and independent revocation enforcement.
2. Database migration 040 structure (revoked_by_user_id, revoked_by_subject, indexes, foreign keys).
3. Real-time post-revocation upload denial (HTTP 403 Forbidden) across upload endpoints.
4. Operator isolation: revoking a host does not affect operator accounts or permissions.
5. Sibling isolation: revoking host A does not affect sibling host B or other agents.
6. Cross-tenant isolation: strict IDOR rejection on cross-tenant revocation attempts.
7. Re-enrollment and re-claim denial for revoked hosts/agents.
8. Append-only audit logging for revocation events with exact operator attribution.
"""
from __future__ import annotations

import json
import socket
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from external_agent_registration import reset_external_agent_state
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE_SUB = "alice-host-revocation"
BOB_SUB = "bob-host-revocation"
TENANT_A = "tenant-host-a"
TENANT_B = "tenant-host-b"
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
        api_compat.reset_tenant_state(TENANT_A)
        api_compat.reset_tenant_state(TENANT_B)
        reset_external_agent_state()


def test_migration_041_structure() -> None:
    """Validate database migration 041 schema definitions."""
    migration_path = Path(__file__).resolve().parents[1] / "db" / "migrations" / "041_external_host_revocation.sql"
    assert migration_path.exists(), "Migration 041 file must exist"
    sql = migration_path.read_text()

    assert "ALTER TABLE public.external_agent_registrations" in sql
    assert "revoked_by_user_id" in sql
    assert "revoked_by_subject" in sql
    assert "revoked_by_issuer" in sql
    assert "fk_external_agent_revoked_by_user" in sql
    assert "idx_external_agent_registrations_revocation" in sql
    assert "idx_external_agent_registrations_revoked_by" in sql
    assert "DROP TABLE" not in sql


def test_host_revocation_lifecycle(client: TestClient) -> None:
    """Validate complete host registration, enrollment, revocation, and attribution."""
    headers = _bearer(ALICE_SUB)

    # 1. Pre-register external agent
    reg_payload = {
        "agent_id": "agent-host-rev-01",
        "host_id": "host-linux-alpha",
        "host_os": "linux",
        "runtime_profile": "nono-0.73.0-standard",
        "allocated_token_budget": 150000,
        "spiffe_id_pattern": "spiffe://signalloom.demo/platform/signalloom/tenant/tenant-host-a/agent/agent-host-rev-01",
    }
    reg_resp = client.post("/api/v1/external-agents/register", json=reg_payload, headers=headers)
    assert reg_resp.status_code == 201, reg_resp.text
    assert reg_resp.json()["enrollment_status"] == "pending"

    # 2. Enroll the host
    enroll_payload = {
        "schema_version": "1.0.0",
        "agent_id": "agent-host-rev-01",
        "host_id": "host-linux-alpha",
        "key_id": "key-host-alpha-01",
        "key_algorithm": "Ed25519",
        "public_key": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
        "client_nonce": "nonce-alpha-123456789012",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "credential_reference": "spiffe://signalloom.demo/platform/signalloom/tenant/tenant-host-a/agent/agent-host-rev-01",
    }
    enroll_resp = client.post("/v1/external-agents/enroll", json=enroll_payload, headers=headers)
    assert enroll_resp.status_code == 201, enroll_resp.text
    assert enroll_resp.json()["enrollment_state"] == "enrolled"

    # Verify status is enrolled
    get_resp = client.get("/api/v1/external-agents/registrations/agent-host-rev-01", headers=headers)
    assert get_resp.status_code == 200
    assert get_resp.json()["enrollment_status"] == "enrolled"
    assert get_resp.json()["enrolled_at"] is not None

    # 3. Operator revokes the host credential via wire contract endpoint
    revoke_payload = {
        "schema_version": "1.0.0",
        "reason_code": "credential-compromise",
    }
    revoke_resp = client.post(
        "/v1/external-agents/agent-host-rev-01/revocations",
        json=revoke_payload,
        headers=headers,
    )
    assert revoke_resp.status_code == 202, revoke_resp.text
    revoke_data = revoke_resp.json()
    assert revoke_data["schema_version"] == "1.0.0"
    assert revoke_data["agent_id"] == "agent-host-rev-01"
    assert revoke_data["revocation_state"] == "revocation-accepted"
    assert revoke_data["reason_code"] == "credential-compromise"
    assert revoke_data["revoked_at"] is not None

    # 4. Verify detail reflects revoked state with attribution
    detail_resp = client.get("/api/v1/external-agents/registrations/agent-host-rev-01", headers=headers)
    assert detail_resp.status_code == 200
    detail_data = detail_resp.json()
    assert detail_data["enrollment_status"] == "revoked"
    assert detail_data["revoked_at"] is not None
    assert detail_data["revocation_reason"] == "credential-compromise"
    assert detail_data["revoked_by_subject"] == ALICE_SUB

    # 5. Verify audit event was recorded
    audit_events = api_compat._AUDIT_EVENTS.get(TENANT_A, [])
    rev_events = [e for e in audit_events if e["event_type"] == "external_agent.revoked"]
    assert len(rev_events) >= 1
    assert rev_events[-1]["agent_name"] == "agent-host-rev-01"
    assert rev_events[-1]["actor"] == f"{ALICE_SUB}@signalloom.test"


def test_host_revocation_operator_isolation(client: TestClient) -> None:
    """Assert that revoking a host has ZERO impact on operator accounts or privileges."""
    headers = _bearer(ALICE_SUB)

    # 1. Register and revoke an agent
    client.post(
        "/api/v1/external-agents/register",
        json={
            "agent_id": "agent-host-iso-01",
            "host_id": "host-iso-01",
            "allocated_token_budget": 100000,
        },
        headers=headers,
    )
    client.post(
        "/api/v1/external-agents/registrations/agent-host-iso-01/revoke",
        json={"reason": "host-unenrollment"},
        headers=headers,
    )

    # 2. Operator remains fully functional: can query registrations
    list_resp = client.get("/api/v1/external-agents/registrations", headers=headers)
    assert list_resp.status_code == 200
    assert list_resp.json()["total"] >= 1

    # 3. Operator can register a new independent agent
    new_reg_resp = client.post(
        "/api/v1/external-agents/register",
        json={
            "agent_id": "agent-host-iso-02",
            "host_id": "host-iso-02",
            "allocated_token_budget": 200000,
        },
        headers=headers,
    )
    assert new_reg_resp.status_code == 201
    assert new_reg_resp.json()["enrollment_status"] == "pending"

    # 4. Operator can query user preferences and agents
    pref_resp = client.get("/api/user/preferences", headers=headers)
    assert pref_resp.status_code == 200


def test_host_revocation_sibling_agent_isolation(client: TestClient) -> None:
    """Assert that revoking Host A leaves sibling Host B completely functional."""
    headers = _bearer(ALICE_SUB)

    # 1. Register Host A and Host B
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": "agent-sibling-a", "host_id": "host-alpha", "allocated_token_budget": 100000},
        headers=headers,
    )
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": "agent-sibling-b", "host_id": "host-beta", "allocated_token_budget": 100000},
        headers=headers,
    )

    # Enroll both
    client.post(
        "/v1/external-agents/enroll",
        json={
            "schema_version": "1.0.0",
            "agent_id": "agent-sibling-a",
            "host_id": "host-alpha",
            "key_id": "key-alpha",
            "key_algorithm": "Ed25519",
            "public_key": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
            "client_nonce": "nonce-alpha-123456789012",
            "credential_kind": "existing-mtls-identity",
            "credential_scope": "audit-upload-only",
            "credential_bootstrap": "pre-provisioned-out-of-band",
            "credential_reference": "spiffe://signalloom.demo/platform/signalloom/tenant/tenant-host-a/agent/agent-sibling-a",
        },
        headers=headers,
    )
    client.post(
        "/v1/external-agents/enroll",
        json={
            "schema_version": "1.0.0",
            "agent_id": "agent-sibling-b",
            "host_id": "host-beta",
            "key_id": "key-beta",
            "key_algorithm": "Ed25519",
            "public_key": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
            "client_nonce": "nonce-beta-123456789012",
            "credential_kind": "existing-mtls-identity",
            "credential_scope": "audit-upload-only",
            "credential_bootstrap": "pre-provisioned-out-of-band",
            "credential_reference": "spiffe://signalloom.demo/platform/signalloom/tenant/tenant-host-a/agent/agent-sibling-b",
        },
        headers=headers,
    )

    # 2. Revoke Host A
    revoke_resp = client.post(
        "/v1/external-agents/agent-sibling-a/revocations",
        json={"schema_version": "1.0.0", "reason_code": "key-rotation"},
        headers=headers,
    )
    assert revoke_resp.status_code == 202

    # 3. Host B remains enrolled and active
    b_resp = client.get("/api/v1/external-agents/registrations/agent-sibling-b", headers=headers)
    assert b_resp.status_code == 200
    assert b_resp.json()["enrollment_status"] == "enrolled"
    assert b_resp.json()["revoked_at"] is None

    # Host B can upload evidence
    upload_resp = client.post(
        "/v1/external-agents/agent-sibling-b/evidence-uploads",
        json={
            "schema_version": "1.0.0",
            "upload_id": "upload-beta-000000000001",
            "session_id": "session-beta-01",
            "assertion_envelope": {
                "assertions": [{"agent_id": "agent-sibling-b"}],
            },
        },
        headers=headers,
    )
    assert upload_resp.status_code == 202


def test_post_revocation_denial_evidence_uploads(client: TestClient) -> None:
    """Assert that revoked hosts are immediately rejected with HTTP 403 on evidence uploads."""
    headers = _bearer(ALICE_SUB)

    # 1. Pre-register and enroll agent
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": "agent-upload-denial-01", "host_id": "host-denial-01", "allocated_token_budget": 100000},
        headers=headers,
    )
    client.post(
        "/v1/external-agents/enroll",
        json={
            "schema_version": "1.0.0",
            "agent_id": "agent-upload-denial-01",
            "host_id": "host-denial-01",
            "key_id": "key-denial-01",
            "key_algorithm": "Ed25519",
            "public_key": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
            "client_nonce": "nonce-denial-123456789012",
            "credential_kind": "existing-mtls-identity",
            "credential_scope": "audit-upload-only",
            "credential_bootstrap": "pre-provisioned-out-of-band",
            "credential_reference": "spiffe://signalloom.demo/platform/signalloom/tenant/tenant-host-a/agent/agent-upload-denial-01",
        },
        headers=headers,
    )

    # Upload before revocation: succeeds (202 Accepted)
    upload_payload = {
        "schema_version": "1.0.0",
        "upload_id": "upload-pre-revocation-01",
        "session_id": "session-pre-rev-01",
        "assertion_envelope": {
            "assertions": [{"agent_id": "agent-upload-denial-01"}],
        },
    }
    up_resp = client.post(
        "/v1/external-agents/agent-upload-denial-01/evidence-uploads",
        json=upload_payload,
        headers=headers,
    )
    assert up_resp.status_code == 202

    # 2. Revoke host
    rev_resp = client.post(
        "/v1/external-agents/agent-upload-denial-01/revocations",
        json={"schema_version": "1.0.0", "reason_code": "credential-compromise"},
        headers=headers,
    )
    assert rev_resp.status_code == 202

    # 3. Subsequent upload attempt: MUST FAIL IMMEDIATELY with HTTP 403 Forbidden
    denied_upload_resp = client.post(
        "/v1/external-agents/agent-upload-denial-01/evidence-uploads",
        json={
            "schema_version": "1.0.0",
            "upload_id": "upload-post-revocation-01",
            "session_id": "session-post-rev-01",
            "assertion_envelope": {
                "assertions": [{"agent_id": "agent-upload-denial-01"}],
            },
        },
        headers=headers,
    )
    assert denied_upload_resp.status_code == 403, denied_upload_resp.text
    err_body = denied_upload_resp.json()
    err_code = err_body.get("error", {}).get("code") or err_body.get("code") or err_body.get("error_code")
    err_msg = err_body.get("error", {}).get("message") or err_body.get("message") or ""
    assert err_code in ("host_revoked", "forbidden")
    assert "revoked" in err_msg.lower()


def test_post_revocation_denial_audit_sessions(client: TestClient) -> None:
    """Assert that signed audit session ingest rejects uploads for revoked hosts with HTTP 403."""
    headers = _bearer(ALICE_SUB)

    # 1. Register and enroll agent
    agent_id = "agent-audit-denial-01"
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-audit-01", "allocated_token_budget": 100000},
        headers=headers,
    )

    # 2. Revoke agent
    client.post(
        f"/v1/external-agents/{agent_id}/revocations",
        json={"schema_version": "1.0.0", "reason_code": "operator-request"},
        headers=headers,
    )

    # 3. Ingest signed audit session -> rejected with 403 Forbidden
    session_payload = {
        "session_id": "sess-audit-denial-01",
        "agent_id": agent_id,
        "tenant_id": TENANT_A,
        "spiffe_id": f"spiffe://signalloom.demo/platform/signalloom/tenant/{TENANT_A}/agent/{agent_id}",
        "started_at": "2026-09-13T16:00:00Z",
        "ended_at": "2026-09-13T16:05:00Z",
        "events_count": 0,
        "root_hash": "0000000000000000000000000000000000000000000000000000000000000000",
        "signature": "c2lnbmF0dXJlLWZha2UtYXVkaXQ=",
        "events": [],
    }
    ingest_resp = client.post("/api/audit/sessions", json=session_payload, headers=headers)
    assert ingest_resp.status_code == 403, ingest_resp.text
    ingest_body = ingest_resp.json()
    ingest_code = ingest_body.get("error", {}).get("code") or ingest_body.get("code")
    assert ingest_code == "host_revoked"

    # 4. Probe verification endpoint reflects revoked failure
    probe_resp = client.post("/api/audit/sessions/verify", json=session_payload, headers=headers)
    assert probe_resp.status_code == 200
    probe_data = probe_resp.json()
    assert probe_data["valid"] is False
    assert "revoked" in (probe_data["error"] or "").lower()


def test_post_revocation_re_enrollment_and_claim_denial(client: TestClient) -> None:
    """Assert that a revoked agent/host cannot re-enroll or be claimed."""
    headers = _bearer(ALICE_SUB)
    agent_id = "agent-reclaim-denial-01"

    # Register and revoke
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": agent_id, "host_id": "host-reclaim-01", "allocated_token_budget": 100000},
        headers=headers,
    )
    client.post(
        f"/api/v1/external-agents/registrations/{agent_id}/revoke",
        json={"reason": "security-incident"},
        headers=headers,
    )

    # Attempt re-enrollment -> 403 Forbidden
    enroll_resp = client.post(
        "/v1/external-agents/enroll",
        json={
            "schema_version": "1.0.0",
            "agent_id": agent_id,
            "host_id": "host-reclaim-01",
            "key_id": "key-reclaim-01",
            "key_algorithm": "Ed25519",
            "public_key": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
            "client_nonce": "nonce-reclaim-123456789012",
            "credential_kind": "existing-mtls-identity",
            "credential_scope": "audit-upload-only",
            "credential_bootstrap": "pre-provisioned-out-of-band",
            "credential_reference": f"spiffe://signalloom.demo/platform/signalloom/tenant/{TENANT_A}/agent/{agent_id}",
        },
        headers=headers,
    )
    assert enroll_resp.status_code == 403, enroll_resp.text

    # Attempt claim -> 403 Forbidden
    claim_resp = client.post(
        f"/api/v1/external-agents/{agent_id}/claim",
        json={"harness": "nono-0.73.0", "model": "claude-3-5-sonnet"},
        headers=headers,
    )
    assert claim_resp.status_code == 403, claim_resp.text
    claim_body = claim_resp.json()
    claim_code = claim_body.get("error", {}).get("code") or claim_body.get("code")
    assert claim_code == "agent_revoked"


def test_cross_tenant_revocation_isolation(client: TestClient) -> None:
    """Assert IDOR protection: Tenant B cannot revoke Tenant A's host."""
    alice_headers = _bearer(ALICE_SUB)
    bob_headers = _bearer(BOB_SUB)

    # Alice registers agent under Tenant A
    client.post(
        "/api/v1/external-agents/register",
        json={"agent_id": "agent-alice-cross", "host_id": "host-alice-cross", "allocated_token_budget": 100000},
        headers=alice_headers,
    )

    # Bob attempts to revoke Alice's agent -> 404 Not Found (zero IDOR leakage)
    bob_revoke = client.post(
        "/v1/external-agents/agent-alice-cross/revocations",
        json={"schema_version": "1.0.0", "reason_code": "operator-request"},
        headers=bob_headers,
    )
    assert bob_revoke.status_code == 404, bob_revoke.text

    # Alice's agent remains unrevoked
    check_resp = client.get("/api/v1/external-agents/registrations/agent-alice-cross", headers=alice_headers)
    assert check_resp.status_code == 200
    assert check_resp.json()["enrollment_status"] == "pending"
    assert check_resp.json()["revoked_at"] is None
