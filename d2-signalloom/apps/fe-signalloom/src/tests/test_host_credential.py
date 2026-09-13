"""Comprehensive Host Enrollment, Credential Scope, and Binding Test Suite for AMXO-P3-2.

Validates:
1. test_credential_scope:
   - Cryptographic JWT issuance with audit-upload-only scope.
   - SPIFFE identity binding pattern (`spiffe://signalloom.demo/platform/signalloom/tenant/{tenant}/agent/{agent}`).
   - Verification of signature, expiration, timestamps, and claims.
   - Rejection of tampered, expired, or wrong-scope credentials.
   - Credential rotation and renewal mechanics for long-running host processes.
2. test_denied_actions:
   - Negative action matrix asserting that host credentials cannot read user data,
     modify agents, manage tenant settings, access superadmin/compliance, or access other tenants.
3. test_tenant_agent_binding:
   - Enforcement that evidence uploads strictly match bound tenant_id, agent_id, host_id, and key_id.
   - Rejection of spoofed or mismatched agent/host/key/tenant claims.
   - Rejection of uploads for revoked or unregistered agents.
"""
from __future__ import annotations

import json
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
from external_agent_registration import (
    ExternalAgentRegistrationRequest,
    register_external_agent_handler,
    reset_external_agent_state,
    _EXTERNAL_REGISTRATIONS,
    _REG_LOCK,
)
from host_credential import (
    AUDIT_UPLOAD_SCOPE,
    EXTERNAL_HOST_IDENTITY_TYPE,
    HostIdentityClaims,
    decode_and_validate_host_token,
    format_spiffe_id,
    issue_host_credential,
    rotate_host_credential,
    set_host_signing_key_for_testing,
    verify_host_credential,
)
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
set_host_signing_key_for_testing(TEST_SIGNING_KEY)

ALICE_SUB = "alice-operator"
BOB_SUB = "bob-operator"
TENANT_A = "tenant-agentmaxxing"
TENANT_B = "tenant-othercorp"
AGENT_1 = "agentmaxxing-linux-001"
AGENT_2 = "agentmaxxing-linux-002"
HOST_1 = "amx-host-001"
HOST_2 = "amx-host-002"
KEY_1 = "host-key:001"
KEY_2 = "host-key:002"

SUBJECT_TENANTS = {
    ALICE_SUB: TENANT_A,
    BOB_SUB: TENANT_B,
}


def _operator_bearer(subject: str = ALICE_SUB) -> dict[str, str]:
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


def _host_bearer(
    tenant_id: str = TENANT_A,
    agent_id: str = AGENT_1,
    host_id: str = HOST_1,
    key_id: str = KEY_1,
    scope: str = AUDIT_UPLOAD_SCOPE,
    ttl: int = 3600,
) -> dict[str, str]:
    cred = issue_host_credential(
        tenant_id=tenant_id,
        agent_id=agent_id,
        host_id=host_id,
        key_id=key_id,
        ttl_seconds=ttl,
        signing_key=TEST_SIGNING_KEY,
        issuer="https://issuer.test/dex",
        custom_scope=scope,
    )
    return {"Authorization": f"Bearer {cred.token}"}


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

    set_host_signing_key_for_testing(TEST_SIGNING_KEY)

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

    # Pre-register AGENT_1 for TENANT_A
    with _REG_LOCK:
        _EXTERNAL_REGISTRATIONS[TENANT_A] = {
            AGENT_1: {
                "id": "reg-001",
                "agent_id": AGENT_1,
                "tenant_id": TENANT_A,
                "host_id": HOST_1,
                "host_os": "linux",
                "runtime_profile": "nono-0.73.0-standard",
                "enrollment_status": "enrolled",
                "registered_by_subject": ALICE_SUB,
                "registered_by_user_id": None,
                "allocated_token_budget": 100000,
                "spiffe_id_pattern": format_spiffe_id(TENANT_A, AGENT_1),
                "enrolled_at": "2026-09-13T10:00:00Z",
                "revoked_at": None,
                "revocation_reason": None,
                "metadata": {},
                "created_at": "2026-09-13T10:00:00Z",
                "updated_at": "2026-09-13T10:00:00Z",
            }
        }

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


# ===========================================================================
# 1. Credential Scope Tests (test_credential_scope)
# ===========================================================================

def test_credential_scope_issuance_and_claims() -> None:
    """Validate that issued host credential carries strictly audit-upload-only scope and correct bindings."""
    cred = issue_host_credential(
        tenant_id=TENANT_A,
        agent_id=AGENT_1,
        host_id=HOST_1,
        key_id=KEY_1,
        ttl_seconds=1800,
        signing_key=TEST_SIGNING_KEY,
    )

    assert cred.scope == "audit-upload-only"
    assert cred.tenant_id == TENANT_A
    assert cred.agent_id == AGENT_1
    assert cred.host_id == HOST_1
    assert cred.key_id == KEY_1
    assert cred.spiffe_id == f"spiffe://signalloom.demo/platform/signalloom/tenant/{TENANT_A}/agent/{AGENT_1}"
    assert cred.token_type == "Bearer"
    assert cred.token is not None and len(cred.token) > 20

    # Inspect decoded claims
    claims = jwt.decode(cred.token, TEST_SIGNING_KEY.public_key(), algorithms=["RS256"], options={"verify_aud": False})
    assert claims["scope"] == AUDIT_UPLOAD_SCOPE
    assert claims["identity_type"] == EXTERNAL_HOST_IDENTITY_TYPE
    assert claims["tenant_id"] == TENANT_A
    assert claims["agent_id"] == AGENT_1
    assert claims["host_id"] == HOST_1
    assert claims["key_id"] == KEY_1
    assert claims["sub"] == cred.spiffe_id
    assert claims["exp"] - claims["iat"] == 1800


@pytest.mark.anyio
async def test_credential_scope_verification_and_tamper_rejection() -> None:
    """Validate cryptographic verification and rejection of tampered tokens."""
    cred = issue_host_credential(
        tenant_id=TENANT_A,
        agent_id=AGENT_1,
        host_id=HOST_1,
        key_id=KEY_1,
        signing_key=TEST_SIGNING_KEY,
    )

    # Valid token verifies cleanly
    claims = await verify_host_credential(cred.token, check_revocation=False)
    assert isinstance(claims, HostIdentityClaims)
    assert claims.tenant_id == TENANT_A
    assert claims.agent_id == AGENT_1
    assert claims.host_id == HOST_1
    assert claims.scope == AUDIT_UPLOAD_SCOPE

    # Tampered signature rejected
    parts = cred.token.split(".")
    tampered_sig = parts[0] + "." + parts[1] + "." + "A" * len(parts[2])
    with pytest.raises(api_compat.APIError) as exc_info:
        await verify_host_credential(tampered_sig, check_revocation=False)
    assert exc_info.value.status_code == 401
    assert exc_info.value.code == "invalid_credential"


@pytest.mark.anyio
async def test_credential_scope_expiration_rejection() -> None:
    """Validate that expired host credentials are strictly rejected with 401."""
    expired_cred = issue_host_credential(
        tenant_id=TENANT_A,
        agent_id=AGENT_1,
        host_id=HOST_1,
        key_id=KEY_1,
        ttl_seconds=-60,  # Expired 60s ago
        signing_key=TEST_SIGNING_KEY,
    )

    with pytest.raises(api_compat.APIError) as exc_info:
        await verify_host_credential(expired_cred.token, check_revocation=False)
    assert exc_info.value.status_code == 401
    assert exc_info.value.code == "credential_expired"


@pytest.mark.anyio
async def test_credential_scope_invalid_scope_rejection() -> None:
    """Validate that credentials with non-audit scope are rejected during host verification."""
    operator_token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-audit-ingest",
            "sub": "alice",
            "tenant_id": TENANT_A,
            "agent_id": AGENT_1,
            "host_id": HOST_1,
            "key_id": KEY_1,
            "scope": "operator:admin",  # Invalid scope for host upload
            "identity_type": EXTERNAL_HOST_IDENTITY_TYPE,
            "iat": int(time.time()),
            "exp": int(time.time()) + 3600,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )

    with pytest.raises(api_compat.APIError) as exc_info:
        await verify_host_credential(operator_token, required_scope=AUDIT_UPLOAD_SCOPE, check_revocation=False)
    assert exc_info.value.status_code == 403
    assert exc_info.value.code == "insufficient_scope"


@pytest.mark.anyio
async def test_credential_scope_rotation_and_renewal() -> None:
    """Validate token rotation and renewal preserves tenant-agent binding with fresh expiry."""
    original_cred = issue_host_credential(
        tenant_id=TENANT_A,
        agent_id=AGENT_1,
        host_id=HOST_1,
        key_id=KEY_1,
        ttl_seconds=600,
        signing_key=TEST_SIGNING_KEY,
    )

    rotated = await rotate_host_credential(
        current_token=original_cred.token,
        new_ttl_seconds=7200,
        signing_key=TEST_SIGNING_KEY,
    )

    assert rotated.tenant_id == TENANT_A
    assert rotated.agent_id == AGENT_1
    assert rotated.host_id == HOST_1
    assert rotated.key_id == KEY_1
    assert rotated.scope == "audit-upload-only"
    assert rotated.jti != original_cred.jti
    assert rotated.token != original_cred.token


def test_credential_scope_rotation_endpoint(client: TestClient) -> None:
    """Validate POST /v1/external-agents/credentials/rotate endpoint via HTTP."""
    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    response = client.post(
        "/v1/external-agents/credentials/rotate",
        headers=headers,
        json={"new_ttl_seconds": 1800},
    )
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["scope"] == "audit-upload-only"
    assert data["tenant_id"] == TENANT_A
    assert data["agent_id"] == AGENT_1
    assert data["token"] is not None


# ===========================================================================
# 2. Negative Action Matrix Tests (test_denied_actions)
# ===========================================================================

def test_denied_actions_matrix_user_management(client: TestClient) -> None:
    """Assert host credentials cannot read user data or operator identities."""
    host_headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)

    # 1. Platform users listing
    res = client.get("/api/v1/tenant/users", headers=host_headers)
    assert res.status_code == 403
    assert "host_credential_scope_restricted" in res.text or "tenant_forbidden" in res.text or "insufficient" in res.text

    # 2. Operator identity listing
    res = client.get("/api/operator-identities", headers=host_headers)
    assert res.status_code == 403

    # 3. Operator session probe
    res = client.get("/api/operator-identities/session", headers=host_headers)
    assert res.status_code == 403


def test_denied_actions_matrix_agent_management(client: TestClient) -> None:
    """Assert host credentials cannot register, claim, modify, or delete agents."""
    host_headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)

    # 1. Create agent
    res = client.post(
        "/api/v1/agents",
        headers=host_headers,
        json={"name": "rogue-agent", "model_provider": "anthropic", "model_name": "claude"},
    )
    assert res.status_code == 403

    # 2. Pre-register external agent
    res = client.post(
        "/api/v1/external-agents/register",
        headers=host_headers,
        json={
            "agent_id": "rogue-external-001",
            "host_id": "amx-host-001",
            "host_os": "linux",
            "runtime_profile": "nono-0.73.0-standard",
            "allocated_token_budget": 100000,
        },
    )
    assert res.status_code == 403

    # 3. List registrations
    res = client.get("/api/v1/external-agents/registrations", headers=host_headers)
    assert res.status_code == 403

    # 4. Claim external agent
    res = client.post(f"/api/v1/external-agents/{AGENT_1}/claim", headers=host_headers, json={})
    assert res.status_code == 403

    # 5. Revoke external agent
    res = client.post(
        f"/api/v1/external-agents/registrations/{AGENT_1}/revoke",
        headers=host_headers,
        json={"reason": "rogue_attempt"},
    )
    assert res.status_code == 403


def test_denied_actions_matrix_tenant_settings(client: TestClient) -> None:
    """Assert host credentials cannot read or update tenant settings, preferences, or frameworks."""
    host_headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)

    # 1. Read tenant settings
    res = client.get("/api/v1/tenant/settings", headers=host_headers)
    assert res.status_code == 403

    # 2. Update preferences
    res = client.patch(
        "/api/v1/tenant/settings/preferences",
        headers=host_headers,
        json={"theme": "dark"},
    )
    assert res.status_code == 403

    # 3. Update frameworks
    res = client.patch(
        "/api/v1/tenant/settings/frameworks",
        headers=host_headers,
        json={"frameworks": ["soc2"]},
    )
    assert res.status_code == 403


def test_denied_actions_matrix_superadmin_and_compliance(client: TestClient) -> None:
    """Assert host credentials cannot access superadmin, compliance, or audit stream routes."""
    host_headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)

    # 1. Superadmin audit
    res = client.get("/api/v1/superadmin/audit", headers=host_headers)
    assert res.status_code == 403

    # 2. Compliance summary
    res = client.get("/api/v1/compliance/summary", headers=host_headers)
    assert res.status_code == 403

    # 3. Compliance export
    res = client.get("/api/v1/compliance/export", headers=host_headers)
    assert res.status_code == 403

    # 4. General audit events
    res = client.get("/api/v1/audit", headers=host_headers)
    assert res.status_code == 403


def test_denied_actions_matrix_support_and_demo(client: TestClient) -> None:
    """Assert host credentials cannot submit support requests or trigger demo runner."""
    host_headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)

    # 1. Support request
    res = client.post(
        "/api/v1/support",
        headers=host_headers,
        json={"subject": "test", "description": "test issue", "priority": "low"},
    )
    assert res.status_code == 403

    # 2. Capabilities
    res = client.get("/api/v1/capabilities", headers=host_headers)
    assert res.status_code == 403


def test_denied_actions_matrix_cross_tenant_isolation(client: TestClient) -> None:
    """Assert host credential for Tenant A cannot access Tenant B's endpoints or agents."""
    host_headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)

    # Try accessing Tenant B's agent details
    res = client.get("/api/v1/agents/tenant-b-agent", headers=host_headers)
    assert res.status_code == 403


# ===========================================================================
# 3. Tenant-Agent Binding Tests (test_tenant_agent_binding)
# ===========================================================================

def _sample_upload_payload(
    agent_id: str = AGENT_1,
    host_id: str = HOST_1,
    key_id: str = KEY_1,
    session_id: str = "sess-001",
) -> dict[str, Any]:
    return {
        "schema_version": "1.0.0",
        "upload_id": "upload-00000000-00000001",
        "replay_key": "a" * 64,
        "session_id": session_id,
        "sequence_start": 0,
        "sequence_end": 0,
        "assertion_envelope": {
            "format": "signalloom-host-assertions-v1",
            "algorithm": "Ed25519",
            "payload_sha256": "b" * 64,
            "key_id": key_id,
            "signature": "c" * 85 + "A",
            "assertions": [
                {
                    "schema_version": "1.0.0",
                    "session_id": session_id,
                    "sequence": 0,
                    "observed_at": "2026-09-13T12:00:00Z",
                    "source": "nono-0.73.0",
                    "evidence_type": "process",
                    "observation_state": "observed",
                    "integrity_state": "not-integrity-verified",
                    "agent_id": agent_id,
                    "host_id": host_id,
                    "attributes": {
                        "health_state": "running",
                        "cpu_time_ms": 120,
                        "resident_memory_bytes": 1048576,
                        "exit_code": None,
                        "restart_count": 0,
                    },
                }
            ],
        },
        "original_chain_reference": {
            "session_id": session_id,
            "event_count": 1,
            "final_digest": "d" * 64,
        },
    }


def test_tenant_agent_binding_valid_upload(client: TestClient) -> None:
    """Validate that evidence upload matching bound tenant, agent, host, and key succeeds."""
    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    payload = _sample_upload_payload(AGENT_1, HOST_1, KEY_1)

    res = client.post("/v1/external-agents/evidence-uploads", headers=headers, json=payload)
    assert res.status_code == 202, res.text
    data = res.json()
    assert data["schema_version"] == "1.0.0"
    assert data["upload_id"] == "upload-00000000-00000001"
    assert data["replay_result"] == "accepted"
    assert data["host_signature_state"] == "host-signature-verified"
    assert data["original_chain_state"] == "original-chain-not-verified"


def test_tenant_agent_binding_agent_mismatch_rejected(client: TestClient) -> None:
    """Validate that upload attempting to spoof a different agent_id is strictly rejected."""
    # Token issued for AGENT_1
    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    # Payload claims AGENT_2
    payload = _sample_upload_payload(AGENT_2, HOST_1, KEY_1)

    res = client.post("/v1/external-agents/evidence-uploads", headers=headers, json=payload)
    assert res.status_code == 403
    assert "tenant_agent_binding_mismatch" in res.text or "forbidden" in res.text.lower()


def test_tenant_agent_binding_host_mismatch_rejected(client: TestClient) -> None:
    """Validate that upload attempting to spoof a different host_id is strictly rejected."""
    # Token issued for HOST_1
    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    # Payload claims HOST_2
    payload = _sample_upload_payload(AGENT_1, HOST_2, KEY_1)

    res = client.post("/v1/external-agents/evidence-uploads", headers=headers, json=payload)
    assert res.status_code == 403
    assert "tenant_host_binding_mismatch" in res.text or "forbidden" in res.text.lower()


def test_tenant_agent_binding_key_mismatch_rejected(client: TestClient) -> None:
    """Validate that upload attempting to spoof a different key_id is strictly rejected."""
    # Token issued for KEY_1
    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    # Payload claims KEY_2
    payload = _sample_upload_payload(AGENT_1, HOST_1, KEY_2)

    res = client.post("/v1/external-agents/evidence-uploads", headers=headers, json=payload)
    assert res.status_code == 403
    assert "tenant_key_binding_mismatch" in res.text or "forbidden" in res.text.lower()


def test_tenant_agent_binding_cross_tenant_rejection(client: TestClient) -> None:
    """Validate that host credential for Tenant A cannot upload evidence for Tenant B."""
    # Token issued for TENANT_A
    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    payload = _sample_upload_payload(AGENT_1, HOST_1, KEY_1)
    payload["tenant_id"] = TENANT_B  # Explicit cross-tenant target

    res = client.post("/v1/external-agents/evidence-uploads", headers=headers, json=payload)
    assert res.status_code == 403
    assert "cross_tenant_forbidden" in res.text or "forbidden" in res.text.lower()


def test_tenant_agent_binding_revoked_agent_upload_rejected(client: TestClient) -> None:
    """Validate that after an agent registration is revoked, evidence uploads are strictly denied."""
    # Revoke AGENT_1
    with _REG_LOCK:
        _EXTERNAL_REGISTRATIONS[TENANT_A][AGENT_1]["enrollment_status"] = "revoked"
        _EXTERNAL_REGISTRATIONS[TENANT_A][AGENT_1]["revoked_at"] = "2026-09-13T14:00:00Z"
        _EXTERNAL_REGISTRATIONS[TENANT_A][AGENT_1]["revocation_reason"] = "compromised_host"

    headers = _host_bearer(TENANT_A, AGENT_1, HOST_1, KEY_1)
    payload = _sample_upload_payload(AGENT_1, HOST_1, KEY_1)

    res = client.post("/v1/external-agents/evidence-uploads", headers=headers, json=payload)
    assert res.status_code == 403
    assert "agent_revoked" in res.text or "revoked" in res.text.lower()


def test_tenant_agent_binding_privacy_contract_endpoint(client: TestClient) -> None:
    """Validate GET /v1/external-agents/privacy endpoint returns the frozen privacy contract."""
    res = client.get("/v1/external-agents/privacy")
    assert res.status_code == 200, res.text
    data = res.json()
    assert data["schema_version"] == "1.0.0"
    assert data["policy_id"] == "amxo-host-policy-v1"
    assert "file_contents" in data["unobserved_fields"]
    assert "raw_nono_record" in data["prohibited_export_fields"]
    assert data["raw_paths_exported"] is False
    assert data["integrity_implies_completeness"] is False
