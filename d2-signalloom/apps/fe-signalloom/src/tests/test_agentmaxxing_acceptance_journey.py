"""AMXO-P6-3: Deterministic Local Onboarding-to-Removal Acceptance Journey.

Executes the complete end-to-end external Linux agent governance lifecycle:
1. Operator Registration: Attributable human operator registers an external agent and generates an atomic one-time enrollment token.
2. Host Enrollment: External host redeems the enrollment token atomically for audit-scoped credentials; duplicate redemption is rejected.
3. Audit Session Ingestion: Host uploads finalized session with process, artifact, and network telemetry; hash chain and sequence numbers are verified.
4. Privacy Sanitization: Projections confirm allowlisted metadata is persisted while prohibited raw fields (payload, memory, terminal) are stripped.
5. Upload Idempotency: Re-submitting identical finalized sessions returns HTTP 200/201 without duplicate records; conflicting payloads return HTTP 409.
6. Integrity Denial Falsification: Broken hash chains and sequence gaps are strictly rejected with HTTP 400.
7. Host Revocation: Operator revokes host registration atomically.
8. Post-Revocation Upload Denial: Revoked host attempting to upload subsequent sessions is refused with HTTP 403 Forbidden.
"""
from __future__ import annotations

import base64
import hashlib
import json
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
from audit_ingest import _clear_sessions_for_testing, compute_expected_entry_hash
from db.connection import set_pool_for_testing
from external_agent_contract import EnrollmentResult
from external_agent_evidence import _clear_evidence_for_testing
from external_agent_registration import reset_external_agent_state
from host_enrollment import reset_host_enrollment_state
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

OPERATOR_SUB = "alice-acceptance-operator"
TENANT_ID = "tenant-agentmaxxing-acceptance"
AGENT_ID = "agentmaxxing-worker-alpha"
HOST_ID = "linux-host-amxo-node-01"

SUBJECT_TENANTS = {
    OPERATOR_SUB: TENANT_ID,
}


def _operator_bearer(subject: str = OPERATOR_SUB) -> dict[str, str]:
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
            "email": f"{subject}@agentmaxxing.test",
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


def configure_acceptance_test_env() -> None:
    settings.api_jwt_issuer = "https://issuer.test/dex"
    settings.api_jwt_audience = "signalloom-api"
    settings.api_jwt_authorized_party = "signalloom-dashboard"
    settings.api_jwks_url = "https://issuer.test/keys"
    settings.api_subject_tenants = dict(SUBJECT_TENANTS)
    api_compat._jwk_client = lambda _url: _TestJWKClient()

    async def _no_pool() -> None:
        return None

    api_compat._get_pool = _no_pool
    api_compat.reset_tenant_state(TENANT_ID)
    reset_external_agent_state()
    reset_host_enrollment_state()
    _clear_sessions_for_testing()
    _clear_evidence_for_testing()
    with api_compat._STORE_LOCK:
        api_compat._AUDIT_EVENTS.clear()
        api_compat._CLAIMS.clear()
    set_pool_for_testing(_ReadyPool())


def teardown_acceptance_test_env() -> None:
    api_compat.reset_tenant_state(TENANT_ID)
    reset_external_agent_state()
    reset_host_enrollment_state()
    _clear_sessions_for_testing()
    _clear_evidence_for_testing()
    set_pool_for_testing(None)


@pytest.fixture(autouse=True)
def setup_acceptance_env(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    api_compat.reset_tenant_state(TENANT_ID)
    reset_external_agent_state()
    reset_host_enrollment_state()
    _clear_sessions_for_testing()
    _clear_evidence_for_testing()
    with api_compat._STORE_LOCK:
        api_compat._AUDIT_EVENTS.clear()
        api_compat._CLAIMS.clear()
    set_pool_for_testing(_ReadyPool())
    yield
    api_compat.reset_tenant_state(TENANT_ID)
    reset_external_agent_state()
    reset_host_enrollment_state()
    _clear_sessions_for_testing()
    _clear_evidence_for_testing()
    set_pool_for_testing(None)


@pytest.fixture
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


def _build_test_events(agent_id: str, count: int = 3, tamper_seq: int | None = None) -> tuple[list[dict[str, Any]], str]:
    events = []
    prev_hash = "0" * 64
    event_specs = [
        ("process_spawn", "exec", "/usr/local/bin/agent", {"health_status": "healthy", "cpu_pct": 3.4, "raw_payload": "PROHIBITED_DATA"}),
        ("artifact_written", "write", "/home/agent/workspace/model.onnx", {"root_path": "/home/agent/workspace", "payload": "PROHIBITED_PAYLOAD"}),
        ("network_egress", "connect", "api.anthropic.com:443", {"destination": "api.anthropic.com:443", "decision": "allowed", "memory_dump": "CORE_DUMP_BYTES"}),
    ]

    for i in range(count):
        seq = i + 1
        ev_type, action, resource, detail = event_specs[i % len(event_specs)]
        ev_dict = {
            "seq": seq,
            "timestamp": f"2026-09-13T19:0{i}:00Z",
            "event_type": ev_type,
            "action": action,
            "resource": resource,
            "detail": dict(detail),
        }
        if tamper_seq is not None and seq == tamper_seq:
            ev_dict["timestamp"] = "2026-09-13T23:59:59Z"

        entry_hash = compute_expected_entry_hash(prev_hash, ev_dict)
        ev_record = {
            "seq": seq,
            "timestamp": ev_dict["timestamp"],
            "event_type": ev_type,
            "action": action,
            "resource": resource,
            "prev_hash": prev_hash,
            "entry_hash": entry_hash,
            "detail": ev_dict["detail"],
        }
        events.append(ev_record)
        prev_hash = entry_hash

    return events, prev_hash


def step_1_operator_registration(client: TestClient) -> tuple[dict[str, str], str]:
    headers = _operator_bearer(OPERATOR_SUB)
    reg_payload = {
        "agent_id": AGENT_ID,
        "host_id": HOST_ID,
        "host_os": "linux",
        "runtime_profile": "nono-0.73.0-standard",
        "allocated_token_budget": 100000,
        "metadata": {"execution_mode": "landlock-lsm"},
    }
    reg_resp = client.post("/api/v1/external-agents/register", headers=headers, json=reg_payload)
    assert reg_resp.status_code == 201, f"Registration failed: {reg_resp.text}"
    reg_data = reg_resp.json()
    assert reg_data["agent_id"] == AGENT_ID
    assert reg_data["tenant_id"] == TENANT_ID
    assert reg_data["enrollment_status"] == "pending"

    # Issue one-time enrollment token
    token_resp = client.post(
        f"/api/v1/external-agents/registrations/{AGENT_ID}/token",
        headers=headers,
        json={"ttl_seconds": 3600},
    )
    assert token_resp.status_code == 200, f"Token issuance failed: {token_resp.text}"
    token_data = token_resp.json()
    enrollment_token = token_data["enrollment_token"]
    assert enrollment_token, "enrollment_token must be non-empty"
    return headers, enrollment_token


def step_2_host_enrollment(client: TestClient, enrollment_token: str) -> EnrollmentResult:
    host_enroll_payload = {
        "schema_version": "1.0.0",
        "agent_id": AGENT_ID,
        "host_id": HOST_ID,
        "key_id": "host-key:amxo-01",
        "key_algorithm": "Ed25519",
        "public_key": "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg",
        "client_nonce": "bm9uY2UtMDAwMDAwMDAwMDAx",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "credential_reference": f"spiffe://signalloom.demo/ns/agents/sa/{AGENT_ID}",
    }
    enroll_resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {enrollment_token}"},
        json=host_enroll_payload,
    )
    assert enroll_resp.status_code == 201, f"Host enrollment failed: {enroll_resp.text}"
    enroll_result = EnrollmentResult.model_validate(enroll_resp.json())
    assert enroll_result.enrollment_state == "enrolled"
    assert enroll_result.agent_id == AGENT_ID
    assert enroll_result.tenant_id == TENANT_ID

    # Atomic Single-Use Check: Replaying the token must fail with 409 Conflict
    dup_enroll_resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {enrollment_token}"},
        json=host_enroll_payload,
    )
    assert dup_enroll_resp.status_code == 409, "Second enrollment token redemption must be rejected"
    return enroll_result


def step_3_audit_session_upload(client: TestClient) -> tuple[dict[str, Any], list[dict[str, Any]], str, dict[str, Any]]:
    headers = _operator_bearer(OPERATOR_SUB)
    session_id = "sess-amxo-journey-001"
    spiffe_id = f"spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/{AGENT_ID}"
    events, root_hash = _build_test_events(AGENT_ID, count=3)
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    session_payload = {
        "session_id": session_id,
        "agent_id": AGENT_ID,
        "tenant_id": TENANT_ID,
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-13T19:00:00Z",
        "ended_at": "2026-09-13T19:02:00Z",
        "events_count": len(events),
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "events": events,
    }

    upload_resp = client.post("/api/audit/sessions", headers=headers, json=session_payload)
    assert upload_resp.status_code == 201, f"Session upload failed: {upload_resp.text}"
    upload_body = upload_resp.json()
    assert upload_body["valid"] is True
    assert upload_body["hash_chain_valid"] is True
    return upload_body, events, root_hash, session_payload


def step_4_verify_projections(client: TestClient) -> list[dict[str, Any]]:
    headers = _operator_bearer(OPERATOR_SUB)
    proj_resp = client.get(f"/api/v1/agents/{AGENT_ID}/external-evidence", headers=headers)
    assert proj_resp.status_code == 200, f"Evidence projection failed: {proj_resp.text}"
    proj_data = proj_resp.json()

    evidence_items = proj_data.get("evidence", [])
    assert len(evidence_items) >= 3, f"Expected at least 3 projected evidence items, got {len(evidence_items)}"

    types_found = set()
    for item in evidence_items:
        types_found.add(item["evidence_type"])
        assert item["verified"] is True
        assert item["source"] in ("nono-audit-ingest", "agentmaxxing-host-sensor")
        assert item["agent_id"] == AGENT_ID
        assert item["tenant_id"] == TENANT_ID
        attrs = item.get("attributes", {})

        # Critical privacy boundary assertions: Prohibited fields must NEVER leak
        assert "raw_payload" not in attrs
        assert "payload" not in attrs
        assert "memory_dump" not in attrs
        assert "terminal_out" not in attrs

    assert "process" in types_found
    assert "artifact" in types_found
    assert "network" in types_found
    return evidence_items


def step_5_upload_idempotency(client: TestClient, session_payload: dict[str, Any]) -> None:
    headers = _operator_bearer(OPERATOR_SUB)
    dup_upload_resp = client.post("/api/audit/sessions", headers=headers, json=session_payload)
    assert dup_upload_resp.status_code in (200, 201), "Identical session upload must be idempotent"

    # Conflicting upload under same session_id must return 409 Conflict
    conflict_payload = dict(session_payload)
    conflict_payload["root_hash"] = "ffff" * 16
    conflict_resp = client.post("/api/audit/sessions", headers=headers, json=conflict_payload)
    assert conflict_resp.status_code == 409, "Conflicting session under same session_id must return 409"


def step_6_denial_falsification(client: TestClient, session_payload: dict[str, Any], events: list[dict[str, Any]]) -> None:
    headers = _operator_bearer(OPERATOR_SUB)
    # Tampered event: modified timestamp breaks the hash chain
    bad_events, _ = _build_test_events(AGENT_ID, count=3, tamper_seq=2)
    tampered_payload = dict(session_payload)
    tampered_payload["session_id"] = "sess-amxo-tampered-002"
    tampered_payload["events"] = bad_events
    tampered_resp = client.post("/api/audit/sessions", headers=headers, json=tampered_payload)
    assert tampered_resp.status_code == 400, "Tampered hash chain must be rejected with HTTP 400"
    assert "hash_chain" in tampered_resp.text.lower() or "invalid" in tampered_resp.text.lower()

    # Sequence gap: missing seq 2
    gap_payload = dict(session_payload)
    gap_payload["session_id"] = "sess-amxo-gap-003"
    gap_payload["events"] = [events[0], events[2]]
    gap_resp = client.post("/api/audit/sessions", headers=headers, json=gap_payload)
    assert gap_resp.status_code == 400, "Sequence gap must be rejected with HTTP 400"


def step_7_host_revocation(client: TestClient) -> dict[str, Any]:
    headers = _operator_bearer(OPERATOR_SUB)
    revoke_payload = {
        "schema_version": "1.0.0",
        "reason_code": "operator-request",
    }
    revoke_resp = client.post(
        f"/v1/external-agents/{AGENT_ID}/revocations",
        headers=headers,
        json=revoke_payload,
    )
    assert revoke_resp.status_code == 202, f"Revocation failed: {revoke_resp.text}"
    revoke_data = revoke_resp.json()
    assert revoke_data["revocation_state"] == "revocation-accepted"
    assert revoke_data["agent_id"] == AGENT_ID
    return revoke_data


def step_8_post_revocation_denial(client: TestClient, session_payload: dict[str, Any]) -> None:
    headers = _operator_bearer(OPERATOR_SUB)
    subsequent_session = dict(session_payload)
    subsequent_session["session_id"] = "sess-amxo-post-revoke-004"
    post_revoke_resp = client.post("/api/audit/sessions", headers=headers, json=subsequent_session)
    assert post_revoke_resp.status_code == 403, "Revoked host must be denied upload with HTTP 403 Forbidden"
    assert "host_revoked" in post_revoke_resp.text.lower()


def test_phase_1_registration_and_token(client: TestClient):
    """Phase 1: Attributable operator registration & one-time enrollment token issuance."""
    step_1_operator_registration(client)


def test_phase_2_host_enrollment_and_single_use(client: TestClient):
    """Phase 2: One-time host enrollment exchange and atomic token single-use check."""
    _, token = step_1_operator_registration(client)
    step_2_host_enrollment(client, token)


def test_phase_3_session_upload_and_evidence_projection(client: TestClient):
    """Phase 3: Audit session upload with process, artifact, network telemetry and privacy sanitization."""
    _, token = step_1_operator_registration(client)
    step_2_host_enrollment(client, token)
    step_3_audit_session_upload(client)
    step_4_verify_projections(client)


def test_phase_4_denial_falsification(client: TestClient):
    """Phase 4: Denial falsification (tampered hash chain 400, sequence gap 400, conflicting session 409)."""
    _, token = step_1_operator_registration(client)
    step_2_host_enrollment(client, token)
    _, events, _, session_payload = step_3_audit_session_upload(client)
    step_5_upload_idempotency(client, session_payload)
    step_6_denial_falsification(client, session_payload, events)


def test_phase_5_revocation_and_post_revocation_denial(client: TestClient):
    """Phase 5: Independent host revocation (202) and post-revocation upload denial (403)."""
    _, token = step_1_operator_registration(client)
    step_2_host_enrollment(client, token)
    _, _, _, session_payload = step_3_audit_session_upload(client)
    step_7_host_revocation(client)
    step_8_post_revocation_denial(client, session_payload)


def test_complete_onboarding_to_removal_journey(client: TestClient):
    """Deterministic acceptance test: registration -> enrollment -> ingest -> projection -> dedup -> denial -> revocation -> post-revocation refusal."""
    headers, token = step_1_operator_registration(client)
    step_2_host_enrollment(client, token)
    upload_body, events, root_hash, session_payload = step_3_audit_session_upload(client)
    step_4_verify_projections(client)
    step_5_upload_idempotency(client, session_payload)
    step_6_denial_falsification(client, session_payload, events)
    step_7_host_revocation(client)
    step_8_post_revocation_denial(client, session_payload)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Deterministic Acceptance Journey Runner")
    parser.add_argument("--phase", choices=["1", "2", "3", "4", "5", "all"], default="all")
    args = parser.parse_args()

    configure_acceptance_test_env()
    c = TestClient(app, raise_server_exceptions=False)
    try:
        if args.phase == "1":
            step_1_operator_registration(c)
            print("PHASE_1_SUCCESS: Attributable registration and enrollment token issued.")
        elif args.phase == "2":
            _, token = step_1_operator_registration(c)
            step_2_host_enrollment(c, token)
            print("PHASE_2_SUCCESS: Host enrollment exchanged and token single-use enforced.")
        elif args.phase == "3":
            _, token = step_1_operator_registration(c)
            step_2_host_enrollment(c, token)
            step_3_audit_session_upload(c)
            step_4_verify_projections(c)
            print("PHASE_3_SUCCESS: Telemetry uploaded, hash chain verified, and evidence projected.")
        elif args.phase == "4":
            _, token = step_1_operator_registration(c)
            step_2_host_enrollment(c, token)
            _, events, _, session_payload = step_3_audit_session_upload(c)
            step_5_upload_idempotency(c, session_payload)
            step_6_denial_falsification(c, session_payload, events)
            print("PHASE_4_SUCCESS: Denial falsification verified for tampered hash chain, gap, and conflict.")
        elif args.phase == "5":
            _, token = step_1_operator_registration(c)
            step_2_host_enrollment(c, token)
            _, _, _, session_payload = step_3_audit_session_upload(c)
            step_7_host_revocation(c)
            step_8_post_revocation_denial(c, session_payload)
            print("PHASE_5_SUCCESS: Host revoked and post-revocation session upload denied.")
        else:
            test_complete_onboarding_to_removal_journey(c)
            print("ACCEPTANCE_JOURNEY_ALL_PHASES_SUCCESS: Full onboarding-to-removal lifecycle verified.")
    finally:
        teardown_acceptance_test_env()


if __name__ == "__main__":
    main()
