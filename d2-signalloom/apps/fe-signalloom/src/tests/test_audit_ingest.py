"""Pytest suite for Signed Audit Session Telemetry Ingest & Verification (SLON-P2-2).

Verifies SP-5 signed audit session ingest, hash-chain integrity verification,
cryptographic SPIFFE detached signature checks, tenant isolation, and error paths.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import sys
import time
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
from fastapi.testclient import TestClient

# Ensure src directory is in path
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.dirname(CURRENT_DIR)
if SRC_DIR not in sys.path:
    sys.path.insert(0, SRC_DIR)

import api_compat
from api_compat import settings
from audit_ingest import (
    _clear_sessions_for_testing,
    canonical_event_json,
    compute_expected_entry_hash,
    verify_hash_chain,
    verify_session_signature,
)
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

SUBJECT_TENANTS = {
    "audit-tester": "tenant-audit-test",
    "audit-tenant-a": "tenant-a",
    "audit-tenant-b": "tenant-b",
    "demo-user": "tenant-demo",
}


class _ReadyPool:
    async def close(self) -> None:
        pass


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(subject: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
            "email": f"{subject}@signalloom.local",
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def _bearer(subject: str = "audit-tester") -> dict[str, str]:
    return {"Authorization": f"Bearer {_token_for(subject)}"}


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    _clear_sessions_for_testing()
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


def _build_hash_chained_events(
    count: int = 3,
    start_seq: int = 1,
    tamper_seq: int | None = None,
) -> tuple[list[dict[str, Any]], str]:
    """Helper to construct a deterministic hash-chained sequence of audit events."""
    events = []
    prev_hash = "0000000000000000000000000000000000000000000000000000000000000000"

    for i in range(count):
        seq = start_seq + i
        ev_dict = {
            "seq": seq,
            "timestamp": f"2026-09-10T10:0{i}:00Z",
            "event_type": "process_confinement_event" if i > 0 else "process_spawn",
            "action": "open" if i > 0 else "exec",
            "resource": f"/var/log/audit/step-{i}.log",
            "detail": {"confined": True, "sandbox": "landlock", "step": i},
        }

        entry_hash = compute_expected_entry_hash(prev_hash, ev_dict)

        detail_for_event = dict(ev_dict["detail"])
        if tamper_seq is not None and seq == tamper_seq:
            # Tamper the event content without updating the signed entry_hash
            detail_for_event["tampered"] = True

        events.append({
            "seq": seq,
            "timestamp": ev_dict["timestamp"],
            "event_type": ev_dict["event_type"],
            "action": ev_dict["action"],
            "resource": ev_dict["resource"],
            "detail": detail_for_event,
            "prev_hash": prev_hash,
            "entry_hash": entry_hash,
        })
        prev_hash = entry_hash

    root_hash = events[-1]["entry_hash"] if events else "0000000000000000000000000000000000000000000000000000000000000000"
    return events, root_hash


# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

def test_ingest_valid_signed_audit_session(client: TestClient):
    """Test successful ingestion and verification of a valid signed audit session."""
    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-valid-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
        "metadata": {"substrate": "kind", "lsm": "landlock"},
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 201, res.text
    data = res.json()
    assert data["session_id"] == "sess-test-valid-001"
    assert data["valid"] is True
    assert data["hash_chain_valid"] is True
    assert data["signature_valid"] is True
    assert data["events_verified"] == 3
    assert data["root_hash"] == root_hash


def test_ingest_requires_authentication(client: TestClient):
    """Test that audit session ingest requires bearer authentication."""
    res = client.post("/api/audit/sessions", json={"session_id": "sess-no-auth"})
    assert res.status_code == 401


def test_ingest_rejects_broken_hash_chain(client: TestClient):
    """Test rejection when hash chain prev_hash or content is tampered."""
    events, root_hash = _build_hash_chained_events(3, tamper_seq=2)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-tampered-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "events": events,
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400
    err = res.json()
    assert err["error"]["code"] == "hash_chain_verification_failed"


def test_ingest_rejects_mismatched_root_hash(client: TestClient):
    """Test rejection when session root_hash does not match final event hash."""
    events, _ = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    fake_root = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    sig_digest = hashlib.sha256(f"{fake_root}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-bad-root-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 3,
        "root_hash": fake_root,
        "signature": f"sig-spiffe-{sig_digest}",
        "events": events,
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400
    err = res.json()
    assert err["error"]["code"] == "hash_chain_verification_failed"


def test_ingest_rejects_invalid_signature(client: TestClient):
    """Test rejection when cryptographic signature does not verify."""
    events, root_hash = _build_hash_chained_events(2)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"

    payload = {
        "session_id": "sess-test-bad-sig-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 2,
        "root_hash": root_hash,
        "signature": "sig-spiffe-0000000000000000000000000000000000000000000000000000000000000000",
        "events": events,
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400
    err = res.json()
    assert err["error"]["code"] == "signature_verification_failed"


def test_ingest_with_ecdsa_p256_key(client: TestClient):
    """Test verification with asymmetric ECDSA P-256 key pair."""
    priv_key = ec.generate_private_key(ec.SECP256R1())
    pub_key_pem = priv_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("utf-8")

    events, root_hash = _build_hash_chained_events(2)
    sig_raw = priv_key.sign(root_hash.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
    sig_b64 = base64.b64encode(sig_raw).decode("utf-8")

    payload = {
        "session_id": "sess-test-ecdsa-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced",
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 2,
        "root_hash": root_hash,
        "signature": sig_b64,
        "algorithm": "ECDSA_SHA256",
        "public_key": pub_key_pem,
        "events": events,
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 201
    assert res.json()["signature_valid"] is True


def test_ingest_with_ed25519_key(client: TestClient):
    """Test verification with asymmetric Ed25519 key pair."""
    priv_key = ed25519.Ed25519PrivateKey.generate()
    pub_key_pem = priv_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("utf-8")

    events, root_hash = _build_hash_chained_events(2)
    sig_raw = priv_key.sign(root_hash.encode("utf-8"))
    sig_b64 = base64.b64encode(sig_raw).decode("utf-8")

    payload = {
        "session_id": "sess-test-ed25519-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced",
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 2,
        "root_hash": root_hash,
        "signature": sig_b64,
        "algorithm": "Ed25519",
        "public_key": pub_key_pem,
        "events": events,
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 201
    assert res.json()["signature_valid"] is True


def test_verify_probe_endpoint(client: TestClient):
    """Test the standalone verify probe endpoint without persistence."""
    events, root_hash = _build_hash_chained_events(2)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-probe-verify-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 2,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "events": events,
    }

    res = client.post("/api/audit/sessions/verify", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 200
    data = res.json()
    assert data["valid"] is True
    assert data["hash_chain_valid"] is True
    assert data["signature_valid"] is True


def test_list_and_get_sessions_with_tenant_isolation(client: TestClient):
    """Test listing and querying sessions with strict multi-tenant isolation."""
    # Ingest for tenant A
    events_a, root_a = _build_hash_chained_events(1)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_a = hashlib.sha256(f"{root_a}:{spiffe_id}".encode()).hexdigest()

    client.post(
        "/api/audit/sessions",
        json={
            "session_id": "sess-tenant-a-1",
            "agent_id": "agent-nono-evidenced",
            "spiffe_id": spiffe_id,
            "started_at": "2026-09-10T10:00:00Z",
            "events_count": 1,
            "root_hash": root_a,
            "signature": f"sig-spiffe-{sig_a}",
            "events": events_a,
        },
        headers=_bearer("audit-tenant-a"),
    )

    # Ingest for tenant B
    events_b, root_b = _build_hash_chained_events(1)
    sig_b = hashlib.sha256(f"{root_b}:{spiffe_id}".encode()).hexdigest()

    client.post(
        "/api/audit/sessions",
        json={
            "session_id": "sess-tenant-b-1",
            "agent_id": "agent-standard-baseline",
            "spiffe_id": spiffe_id,
            "started_at": "2026-09-10T10:00:00Z",
            "events_count": 1,
            "root_hash": root_b,
            "signature": f"sig-spiffe-{sig_b}",
            "events": events_b,
        },
        headers=_bearer("audit-tenant-b"),
    )

    # Tenant A list
    res_a = client.get("/api/audit/sessions", headers=_bearer("audit-tenant-a"))
    assert res_a.status_code == 200
    sessions_a = res_a.json()["sessions"]
    assert len(sessions_a) == 1
    assert sessions_a[0]["session_id"] == "sess-tenant-a-1"

    # Tenant A get own session
    res_get_a = client.get("/api/audit/sessions/sess-tenant-a-1", headers=_bearer("audit-tenant-a"))
    assert res_get_a.status_code == 200
    assert res_get_a.json()["session_id"] == "sess-tenant-a-1"

    # Tenant A cannot see Tenant B's session (404)
    res_cross = client.get("/api/audit/sessions/sess-tenant-b-1", headers=_bearer("audit-tenant-a"))
    assert res_cross.status_code == 404

    # Tenant B list
    res_b = client.get("/api/audit/sessions", headers=_bearer("audit-tenant-b"))
    assert res_b.status_code == 200
    sessions_b = res_b.json()["sessions"]
    assert len(sessions_b) == 1
    assert sessions_b[0]["session_id"] == "sess-tenant-b-1"


def test_ingest_with_rsa_key(client: TestClient):
    """Test verification with asymmetric RSA key pair."""
    priv_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub_key_pem = priv_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("utf-8")

    events, root_hash = _build_hash_chained_events(2)
    sig_raw = priv_key.sign(
        root_hash.encode("utf-8"),
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    sig_b64 = base64.b64encode(sig_raw).decode("utf-8")

    payload = {
        "session_id": "sess-test-rsa-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced",
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 2,
        "root_hash": root_hash,
        "signature": sig_b64,
        "algorithm": "RSA_SHA256",
        "public_key": pub_key_pem,
        "events": events,
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 201
    assert res.json()["signature_valid"] is True


def test_ingest_empty_session_with_genesis(client: TestClient):
    """Test empty session with valid genesis root hash."""
    session_id = "sess-empty-001"
    genesis_root = hashlib.sha256(f"{session_id}:genesis".encode()).hexdigest()
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{genesis_root}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": session_id,
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "events_count": 0,
        "root_hash": genesis_root,
        "signature": f"sig-spiffe-{sig_digest}",
        "events": [],
    }

    res = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 201
    data = res.json()
    assert data["valid"] is True
    assert data["events_verified"] == 0


def test_list_sessions_filter_and_pagination(client: TestClient):
    """Test filtering by agent_id and offset/limit pagination."""
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    for i in range(5):
        events, root_hash = _build_hash_chained_events(1)
        sig = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()
        agent = "agent-nono-evidenced" if i < 3 else "agent-standard-baseline"
        client.post(
            "/api/audit/sessions",
            json={
                "session_id": f"sess-page-{i}",
                "agent_id": agent,
                "spiffe_id": spiffe_id,
                "started_at": "2026-09-10T10:00:00Z",
                "events_count": 1,
                "root_hash": root_hash,
                "signature": f"sig-spiffe-{sig}",
                "events": events,
            },
            headers=_bearer("audit-tester"),
        )

    # Filter by agent-nono-evidenced
    res_filtered = client.get(
        "/api/audit/sessions?agent_id=agent-nono-evidenced",
        headers=_bearer("audit-tester"),
    )
    assert res_filtered.status_code == 200
    assert len(res_filtered.json()["sessions"]) == 3

    # Pagination: limit=2, offset=1
    res_page = client.get(
        "/api/audit/sessions?limit=2&offset=1",
        headers=_bearer("audit-tester"),
    )
    assert res_page.status_code == 200
    assert len(res_page.json()["sessions"]) == 2
    assert res_page.json()["total"] == 5


def test_get_nonexistent_session_returns_404(client: TestClient):
    """Test 404 for nonexistent session."""
    res = client.get("/api/audit/sessions/sess-does-not-exist", headers=_bearer("audit-tester"))
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "session_not_found"


def test_canonical_event_json_determinism():
    """Assert canonical JSON formatting is key-order independent and compact."""
    dict1 = {"seq": 1, "timestamp": "2026-09-10T10:00:00Z", "event_type": "open", "action": "read", "resource": "/etc/hosts", "detail": {"a": 1, "b": 2}}
    dict2 = {"detail": {"b": 2, "a": 1}, "resource": "/etc/hosts", "action": "read", "event_type": "open", "timestamp": "2026-09-10T10:00:00Z", "seq": 1}
    assert canonical_event_json(dict1) == canonical_event_json(dict2)


def test_privacy_boundaries() -> None:
    """External host telemetry exports only frozen, attributable safe fields."""
    from pathlib import Path

    from agentmaxxing_host_policy import (
        AttributableIdentity,
        IntegrityState,
        ObservationState,
        classify_boundary,
        filter_host_telemetry,
        load_host_policy,
    )

    fixture_path = (
        Path(__file__).resolve().parents[4]
        / "governance"
        / "fixtures"
        / "agentmaxxing-raw-telemetry.v1.json"
    )
    raw = json.loads(fixture_path.read_text(encoding="utf-8"))
    policy_path = (
        Path(__file__).resolve().parents[4]
        / "governance"
        / "fixtures"
        / "agentmaxxing-host-policy.v1.json"
    )
    exported = filter_host_telemetry(
        raw,
        AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        ),
        load_host_policy(policy_path),
    )

    serialized = json.dumps(exported, sort_keys=True)
    for prohibited_value in raw["prohibited_test_values"]:
        assert prohibited_value not in serialized
    assert exported["tenant_id"] == "tenant-agentmaxxing"
    assert exported["agent_id"] == "agentmaxxing-linux-001"

    absent = classify_boundary(integrity_verified=True)
    assert absent.observation_state is ObservationState.UNOBSERVED
    assert absent.integrity_state is IntegrityState.VERIFIED
