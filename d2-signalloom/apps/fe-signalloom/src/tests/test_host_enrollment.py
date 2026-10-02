"""Tests for AMXO-P3-1: Atomic one-time external host enrollment token exchange.

Covers:
1. Token issuance by authorized operators with CSPRNG entropy and SHA-256 hashing.
2. Single-use atomic redemption with immediate invalidation.
3. Multi-threaded concurrent redemption race condition testing (exactly 1 winner).
4. Expired token rejection.
5. Unregistered, revoked, and mismatched host rejection.
6. Malformed headers, payload validation, and unsupported media types.
7. Contract conformance against frozen JSON and OpenAPI schemas.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import hashlib
import json
import time
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api_compat
from external_agent_contract import EnrollmentRequest, EnrollmentResult
from external_agent_registration import (
    ExternalAgentRegistrationRequest,
    register_external_agent_handler,
    reset_external_agent_state,
)
from host_enrollment import (
    generate_secure_token,
    hash_enrollment_token,
    issue_enrollment_token_for_agent,
    reset_host_enrollment_state,
)

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "signal-ingest/collectors/agentnono/fixtures/contracts"


def load_fixture(name: str) -> dict[str, Any]:
    data = json.loads((FIXTURES / name).read_text())
    if "valid" in name and isinstance(data, dict):
        data.pop("credential_reference", None)
    return data


@pytest.fixture(autouse=True)
def clean_state():
    reset_external_agent_state()
    reset_host_enrollment_state()
    with api_compat._STORE_LOCK:
        api_compat._AUDIT_EVENTS.clear()
        api_compat._CLAIMS.clear()
    yield
    reset_external_agent_state()
    reset_host_enrollment_state()


@pytest.fixture
def operator_principal() -> api_compat.Principal:
    return api_compat.Principal(
        tenant="tenant-a",
        subject="operator-alice",
        email="alice@agentmaxxing.example",
    )


@pytest.fixture
def client(operator_principal: api_compat.Principal) -> TestClient:
    app = FastAPI()
    api_compat.install_compatibility_api(app)
    app.dependency_overrides[api_compat.authenticated_principal] = lambda: operator_principal
    return TestClient(app)


def test_sha256_token_hashing_and_entropy():
    """Verify CSPRNG generation entropy and canonical SHA-256 hashing."""
    tokens = [generate_secure_token() for _ in range(50)]
    assert len(set(tokens)) == 50, "CSPRNG must generate unique tokens"

    for token in tokens:
        token_hash = hash_enrollment_token(token)
        assert len(token_hash) == 64
        assert hashlib.sha256(token.encode("utf-8")).hexdigest() == token_hash


def test_host_enrollment_happy_path(client: TestClient, operator_principal: api_compat.Principal):
    """Test full enrollment lifecycle: pre-register -> issue token -> redeem -> 201 Created."""
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"

    # 1. Pre-register external agent
    reg_req = ExternalAgentRegistrationRequest(
        agent_id=agent_id,
        host_id=host_id,
        host_os="linux",
        runtime_profile="nono-0.73.0-standard",
        allocated_token_budget=150000,
    )
    reg_resp = asyncio.run(register_external_agent_handler(reg_req, operator_principal))
    assert reg_resp.enrollment_status == "pending"

    # 2. Issue one-time enrollment token
    token_resp = asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))
    token = token_resp.enrollment_token
    assert token

    # 3. Redeem token via POST /v1/external-agents/enroll
    enrollment_payload = load_fixture("valid-enrollment.v1.json")
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=enrollment_payload,
    )

    assert resp.status_code == 201, f"Expected 201, got {resp.status_code}: {resp.text}"
    data = resp.json()

    # Validate against EnrollmentResult contract
    result = EnrollmentResult.model_validate(data)
    assert result.schema_version == "1.0.0"
    assert result.tenant_id == "tenant-a"
    assert result.agent_id == agent_id
    assert result.host_id == host_id
    assert result.enrollment_state == "enrolled"
    assert result.credential_kind == "existing-mtls-identity"
    assert result.credential_scope == "audit-upload-only"
    assert result.credential_bootstrap == "pre-provisioned-out-of-band"
    assert result.revocation_endpoint == f"/v1/external-agents/{agent_id}/revocations"

    # Verify audit event was logged
    audit_events = api_compat._AUDIT_EVENTS.get("tenant-a", [])
    claimed_events = [e for e in audit_events if e["event_type"] == "external_agent.claimed"]
    assert len(claimed_events) >= 1
    assert claimed_events[0]["detail"]["agent_id"] == agent_id


def test_host_enrollment_root_route_identical_to_v1(client: TestClient, operator_principal: api_compat.Principal):
    """Assert POST /enroll succeeds identically to POST /v1/external-agents/enroll."""
    agent_id = "agentmaxxing-linux-root-001"
    host_id = "amx-host-root-001"

    # 1. Pre-register external agent
    reg_req = ExternalAgentRegistrationRequest(
        agent_id=agent_id,
        host_id=host_id,
        host_os="linux",
        runtime_profile="nono-0.73.0-standard",
        allocated_token_budget=150000,
    )
    reg_resp = asyncio.run(register_external_agent_handler(reg_req, operator_principal))
    assert reg_resp.enrollment_status == "pending"

    # 2. Issue one-time enrollment token
    token_resp = asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))
    token = token_resp.enrollment_token
    assert token

    # 3. Redeem token via POST /enroll
    enrollment_payload = load_fixture("valid-enrollment.v1.json")
    enrollment_payload["agent_id"] = agent_id
    enrollment_payload["host_id"] = host_id
    enrollment_payload["client_nonce"] = "nonce-root-enroll-identical-test"

    resp = client.post(
        "/enroll",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=enrollment_payload,
    )

    assert resp.status_code == 201, f"Expected 201 from /enroll, got {resp.status_code}: {resp.text}"
    data = resp.json()

    # Validate against EnrollmentResult contract identically to /v1/external-agents/enroll
    result = EnrollmentResult.model_validate(data)
    assert result.schema_version == "1.0.0"
    assert result.tenant_id == "tenant-a"
    assert result.agent_id == agent_id
    assert result.host_id == host_id
    assert result.enrollment_state == "enrolled"
    assert result.credential_kind == "existing-mtls-identity"
    assert result.credential_scope == "audit-upload-only"
    assert result.credential_bootstrap == "pre-provisioned-out-of-band"
    assert result.credential_reference.startswith("spiffe://signalloom.demo/ns/eap-")
    assert result.credential_reference.endswith(f"/sa/agent-{agent_id}")
    assert result.revocation_endpoint == f"/v1/external-agents/{agent_id}/revocations"
    assert result.svid_path == "jwt-svid-fetch"

    # Verify audit event was logged identically
    audit_events = api_compat._AUDIT_EVENTS.get("tenant-a", [])
    claimed_events = [e for e in audit_events if e["event_type"] == "external_agent.claimed"]
    assert len(claimed_events) >= 1
    assert claimed_events[-1]["detail"]["agent_id"] == agent_id



def test_single_use_consumption_and_replay_rejection(client: TestClient, operator_principal: api_compat.Principal):
    """Assert token is single-use and subsequent replays with different nonces are rejected."""
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        operator_principal,
    ))
    token_resp = asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))
    token = token_resp.enrollment_token

    payload = load_fixture("valid-enrollment.v1.json")

    # First redemption: 201 Created
    resp1 = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp1.status_code == 201

    # Second redemption with SAME token but DIFFERENT nonce: 409 Conflict / 401 Unauthenticated
    payload2 = dict(payload)
    payload2["client_nonce"] = "nonce-different-replay-99999"
    resp2 = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload2,
    )
    assert resp2.status_code in (401, 409), f"Replay should fail, got {resp2.status_code}: {resp2.text}"
    err_data = resp2.json()
    assert err_data["error_code"] in ("conflict", "unauthenticated")


def test_concurrent_redemption(client: TestClient, operator_principal: api_compat.Principal):
    """Assert parallel concurrent redemption requests with the same token and distinct nonces result in EXACTLY 1 winner."""
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        operator_principal,
    ))
    token_resp = asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))
    token = token_resp.enrollment_token
    payload = load_fixture("valid-enrollment.v1.json")

    num_threads = 12
    results: list[int] = []

    def make_request(idx: int):
        p = dict(payload)
        p["client_nonce"] = f"nonce-thread-{idx:04d}-unique"
        resp = client.post(
            "/v1/external-agents/enroll",
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json=p,
        )
        return resp.status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = [executor.submit(make_request, i) for i in range(num_threads)]
        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())

    success_count = results.count(201)
    conflict_or_unauth = sum(1 for c in results if c in (401, 409))

    assert success_count == 1, f"Expected exactly 1 success (201), got {success_count}. All results: {results}"
    assert conflict_or_unauth == num_threads - 1, f"Expected {num_threads - 1} rejections, got {conflict_or_unauth}"


def test_expired_token(client: TestClient, operator_principal: api_compat.Principal):
    """Assert expired enrollment token is rejected with 401 Unauthenticated."""
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        operator_principal,
    ))
    # Issue token with negative TTL (already expired)
    token = generate_secure_token()
    token_hash = hash_enrollment_token(token)

    # Manually store expired token in in-memory state
    from external_agent_registration import _EXTERNAL_REGISTRATIONS, _REG_LOCK
    with _REG_LOCK:
        reg = _EXTERNAL_REGISTRATIONS["tenant-a"][agent_id]
        reg["enrollment_token_hash"] = token_hash
        # Expired in the past
        reg["enrollment_token_expires_at"] = "2020-01-01T00:00:00Z"
        reg["enrollment_status"] = "pending"

    payload = load_fixture("valid-enrollment.v1.json")
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 401, f"Expected 401 for expired token, got {resp.status_code}: {resp.text}"
    data = resp.json()
    assert data["error_code"] == "unauthenticated"
    assert "expired" in data["message"].lower()


def test_unregistered_agent_rejection(client: TestClient):
    """Assert enrollment for non-registered agent is rejected with 403 Forbidden."""
    payload = load_fixture("valid-enrollment.v1.json")
    token = generate_secure_token()

    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 403, f"Expected 403 for unregistered agent, got {resp.status_code}: {resp.text}"
    data = resp.json()
    assert data["error_code"] == "forbidden"


def test_revoked_agent_rejection(client: TestClient, operator_principal: api_compat.Principal):
    """Assert enrollment for a revoked agent is rejected with 403 Forbidden."""
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        operator_principal,
    ))
    token_resp = asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))
    token = token_resp.enrollment_token

    # Revoke agent
    from external_agent_registration import _EXTERNAL_REGISTRATIONS, _REG_LOCK
    with _REG_LOCK:
        _EXTERNAL_REGISTRATIONS["tenant-a"][agent_id]["enrollment_status"] = "revoked"

    payload = load_fixture("valid-enrollment.v1.json")
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 403, f"Expected 403 for revoked agent, got {resp.status_code}: {resp.text}"


def test_mismatched_host_id_rejection(client: TestClient, operator_principal: api_compat.Principal):
    """Assert enrollment with mismatched host_id is rejected with 409 Conflict."""
    agent_id = "agentmaxxing-linux-001"
    registered_host_id = "amx-host-999"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=registered_host_id),
        operator_principal,
    ))
    token_resp = asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))
    token = token_resp.enrollment_token

    payload = load_fixture("valid-enrollment.v1.json")  # has host_id: "amx-host-001"
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 409, f"Expected 409 for mismatched host_id, got {resp.status_code}: {resp.text}"
    assert "mismatch" in resp.json()["message"].lower()


def test_invalid_token_rejected(client: TestClient, operator_principal: api_compat.Principal):
    """Assert incorrect token is rejected with 401 Unauthenticated."""
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        operator_principal,
    ))
    asyncio.run(issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600))

    wrong_token = generate_secure_token()
    payload = load_fixture("valid-enrollment.v1.json")

    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {wrong_token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 401
    assert resp.json()["error_code"] == "unauthenticated"


def test_missing_or_invalid_auth_header(client: TestClient):
    """Assert missing or malformed Authorization header fails with 401."""
    payload = load_fixture("valid-enrollment.v1.json")

    # Missing
    resp = client.post("/v1/external-agents/enroll", json=payload)
    assert resp.status_code == 401
    assert resp.json()["error_code"] == "unauthenticated"

    # Basic auth instead of Bearer
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": "Basic dXNlcjpwYXNz"},
        json=payload,
    )
    assert resp.status_code == 401

    # Empty Bearer
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": "Bearer "},
        json=payload,
    )
    assert resp.status_code == 401


def test_unsupported_media_type(client: TestClient):
    """Assert non-JSON Content-Type returns 415 Unsupported Media Type."""
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={
            "Authorization": "Bearer some-token-value-12345",
            "Content-Type": "text/plain",
        },
        content="plain text",
    )
    assert resp.status_code == 415
    assert resp.json()["error_code"] == "unsupported-media-type"


def test_malformed_and_invalid_contract_bodies(client: TestClient):
    """Assert malformed bodies and schema violations return 400 or 422."""
    # Empty body
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": "Bearer some-token-value-12345", "Content-Type": "application/json"},
        content="",
    )
    assert resp.status_code in (400, 422)

    # Malformed JSON
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": "Bearer some-token-value-12345", "Content-Type": "application/json"},
        content="{invalid-json",
    )
    assert resp.status_code in (400, 422)

    # Malformed contract payload from fixture (RSA instead of Ed25519)
    malformed = load_fixture("malformed-enrollment.v1.json")
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": "Bearer some-token-value-12345", "Content-Type": "application/json"},
        json=malformed,
    )
    assert resp.status_code == 422
    assert resp.json()["error_code"] == "validation-failed"


def test_operator_token_issuance_and_rotation_endpoints(client: TestClient):
    """Test operator token issuance and rotation endpoints."""
    admin_principal = api_compat.Principal(
        tenant="tenant-a",
        subject="superadmin-subject",
        email="superadmin@signalloom.test",
    )
    client.app.dependency_overrides[api_compat.authenticated_principal] = lambda: admin_principal

    # Pre-register agent
    agent_id = "agentmaxxing-linux-001"
    host_id = "amx-host-001"
    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        admin_principal,
    ))

    # Issue token via POST /v1/external-agents/registrations/{agent_id}/token
    resp1 = client.post(
        f"/v1/external-agents/registrations/{agent_id}/token",
        json={"ttl_seconds": 7200},
    )
    assert resp1.status_code == 200, f"Expected 200, got {resp1.status_code}: {resp1.text}"
    token1 = resp1.json()["enrollment_token"]
    assert token1

    # Rotate token
    resp2 = client.post(
        f"/v1/external-agents/registrations/{agent_id}/token",
        json={"ttl_seconds": 1800},
    )
    assert resp2.status_code == 200
    token2 = resp2.json()["enrollment_token"]
    assert token2
    assert token1 != token2

    # Old token fails
    payload = load_fixture("valid-enrollment.v1.json")
    resp_old = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token1}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp_old.status_code == 401

    # New rotated token succeeds
    resp_new = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token2}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp_new.status_code == 201


def test_registration_full_lifecycle_and_revocation(client: TestClient):
    """Step 13: Full registration lifecycle with server-minted SPIFFE ID, audit, and revocation."""
    admin_principal = api_compat.Principal(
        tenant="tenant-a",
        subject="operator-alice",
        email="alice@signalloom.test",
    )
    client.app.dependency_overrides[api_compat.authenticated_principal] = lambda: admin_principal

    agent_id = "agent-lifecycle-001"
    host_id = "host-lifecycle-001"

    # 1. Pre-register
    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(
            agent_id=agent_id,
            host_id=host_id,
            host_os="linux",
            runtime_profile="nono-0.73.0-standard",
            allocated_token_budget=100000,
        ),
        admin_principal,
    ))

    # 2. Issue token
    resp_token = client.post(f"/v1/external-agents/registrations/{agent_id}/token", json={"ttl_seconds": 3600})
    assert resp_token.status_code == 200
    token = resp_token.json()["enrollment_token"]

    # 3. Exchange by sensor
    payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_id,
        "host_id": host_id,
        "key_id": "key-lifecycle-001",
        "key_algorithm": "Ed25519",
        "public_key": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
        "client_nonce": "nonce-lifecycle-001-random1234",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
    }
    resp_enroll = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp_enroll.status_code == 201, f"Enroll failed: {resp_enroll.text}"
    enroll_data = resp_enroll.json()

    # Verify server-issued SPIFFE ID under signalloom.demo
    spiffe_id = enroll_data["credential_reference"]
    assert spiffe_id.startswith("spiffe://signalloom.demo/ns/eap-")
    assert spiffe_id.endswith(f"/sa/agent-{agent_id}")
    assert enroll_data["svid_path"] == "jwt-svid-fetch"

    # Verify audit event with spiffe_id
    audit_events = api_compat._AUDIT_EVENTS.get("tenant-a", [])
    claimed_events = [e for e in audit_events if e["event_type"] == "external_agent.claimed"]
    assert len(claimed_events) >= 1
    assert claimed_events[-1]["detail"]["spiffe_id"] == spiffe_id

    # 4. Revoke
    resp_revoke = client.post(f"/v1/external-agents/registrations/{agent_id}/revoke")
    assert resp_revoke.status_code == 200
    revoke_data = resp_revoke.json()
    assert revoke_data["revocation_state"] == "revocation-accepted"
    assert revoke_data["credential_reference"] == spiffe_id

    # Verify revoke audit event
    revoke_events = [e for e in audit_events if e["event_type"] == "external_agent.revoked"]
    assert len(revoke_events) >= 1
    assert revoke_events[-1]["detail"]["spiffe_id"] == spiffe_id

    # 5. Subsequent exchange attempt returns 403
    resp_subsequent = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp_subsequent.status_code == 403


def test_registration_cross_tenant_negative_403(client: TestClient):
    """Step 13 negative: Token for tenant A used to register into tenant B returns 403."""
    admin_principal = api_compat.Principal(
        tenant="tenant-a",
        subject="operator-alice",
        email="alice@signalloom.test",
    )
    client.app.dependency_overrides[api_compat.authenticated_principal] = lambda: admin_principal

    agent_id = "agent-xtenant-002"
    host_id = "host-xtenant-002"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        admin_principal,
    ))
    resp_token = client.post(f"/v1/external-agents/registrations/{agent_id}/token", json={"ttl_seconds": 3600})
    token = resp_token.json()["enrollment_token"]

    payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_id,
        "host_id": host_id,
        "key_id": "key-xtenant-002",
        "key_algorithm": "Ed25519",
        "public_key": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
        "client_nonce": "nonce-xtenant-002-unique7890",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "tenant_id": "tenant-b",
    }
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 403
    assert "tenant mismatch" in resp.json()["message"].lower()

    # Verify audit rejection
    audit_events = api_compat._AUDIT_EVENTS.get("tenant-a", [])
    xtenant_events = [e for e in audit_events if e["event_type"] == "external_agent.cross_tenant_rejected"]
    assert len(xtenant_events) >= 1


def test_registration_idempotency_with_same_nonce(client: TestClient):
    """Step 13: Replay with the same nonce is idempotent and creates no second SPIRE entry."""
    admin_principal = api_compat.Principal(
        tenant="tenant-a",
        subject="operator-alice",
        email="alice@signalloom.test",
    )
    client.app.dependency_overrides[api_compat.authenticated_principal] = lambda: admin_principal

    agent_id = "agent-idemp-003"
    host_id = "host-idemp-003"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        admin_principal,
    ))
    resp_token = client.post(f"/v1/external-agents/registrations/{agent_id}/token", json={"ttl_seconds": 3600})
    token = resp_token.json()["enrollment_token"]

    fixed_nonce = "nonce-idemp-003-static5678"
    payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_id,
        "host_id": host_id,
        "key_id": "key-idemp-003",
        "key_algorithm": "Ed25519",
        "public_key": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
        "client_nonce": fixed_nonce,
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
    }

    # First attempt: 201 Created
    resp1 = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp1.status_code == 201
    spiffe1 = resp1.json()["credential_reference"]

    # Second attempt with same nonce: 201 Created with idempotent result
    resp2 = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp2.status_code == 201
    assert resp2.json()["credential_reference"] == spiffe1


def test_registration_expired_timestamp_negative_401(client: TestClient):
    """Step 13 negative: Timestamp 301 s old returns 401."""
    from datetime import datetime, timedelta, timezone

    admin_principal = api_compat.Principal(
        tenant="tenant-a",
        subject="operator-alice",
        email="alice@signalloom.test",
    )
    client.app.dependency_overrides[api_compat.authenticated_principal] = lambda: admin_principal

    agent_id = "agent-ts-004"
    host_id = "host-ts-004"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        admin_principal,
    ))
    resp_token = client.post(f"/v1/external-agents/registrations/{agent_id}/token", json={"ttl_seconds": 3600})
    token = resp_token.json()["enrollment_token"]

    old_ts = (datetime.now(timezone.utc) - timedelta(seconds=305)).strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_id,
        "host_id": host_id,
        "key_id": "key-ts-004",
        "key_algorithm": "Ed25519",
        "public_key": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
        "client_nonce": "nonce-ts-004-unique4321",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "timestamp": old_ts,
    }
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 401
    assert "300-second validity window" in resp.json()["message"]


def test_registration_client_supplied_credential_reference_negative_422(client: TestClient):
    """Step 13 negative: Body with credential_reference returns 422."""
    admin_principal = api_compat.Principal(
        tenant="tenant-a",
        subject="operator-alice",
        email="alice@signalloom.test",
    )
    client.app.dependency_overrides[api_compat.authenticated_principal] = lambda: admin_principal

    agent_id = "agent-credref-005"
    host_id = "host-credref-005"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id),
        admin_principal,
    ))
    resp_token = client.post(f"/v1/external-agents/registrations/{agent_id}/token", json={"ttl_seconds": 3600})
    token = resp_token.json()["enrollment_token"]

    payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_id,
        "host_id": host_id,
        "key_id": "key-credref-005",
        "key_algorithm": "Ed25519",
        "public_key": "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
        "client_nonce": "nonce-credref-005-unique9999",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "credential_reference": "spiffe://signalloom.demo/ns/eap-tenant-a/sa/agent-injected",
    }
    resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )
    assert resp.status_code == 422
    assert "credential_reference is server-issued" in resp.json()["message"]

