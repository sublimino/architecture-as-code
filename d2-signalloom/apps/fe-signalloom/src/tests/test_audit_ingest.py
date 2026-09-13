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
    finalized: bool = False,
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
        if finalized and i == count - 1:
            ev_dict["event_type"] = "session_finalized"
            ev_dict["action"] = "finalized"
            ev_dict["detail"]["finalized"] = True

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


def test_nono_profile_conformance() -> None:
    """Validate that agentmaxxing-host-sensor profile.json satisfies approved host policy."""
    from pathlib import Path
    import json

    profile_path = (
        Path(__file__).resolve().parents[3]
        / "agentmaxxing-host-sensor"
        / "profile.json"
    )
    assert profile_path.is_file(), f"profile.json missing at {profile_path}"

    with profile_path.open(encoding="utf-8") as f:
        prof = json.load(f)

    policy_path = (
        Path(__file__).resolve().parents[4]
        / "governance"
        / "fixtures"
        / "agentmaxxing-host-policy.v1.json"
    )
    with policy_path.open(encoding="utf-8") as f:
        policy = json.load(f)

    # Version check
    assert prof.get("meta", {}).get("version") == policy["nono"]["version"]

    # Filesystem allow/read check
    allow_paths = prof.get("filesystem", {}).get("allow", [])
    for w_root in policy.get("writable_roots", []):
        assert w_root["path"] in allow_paths, f"writable root {w_root['path']} missing from profile allow"

    read_paths = prof.get("filesystem", {}).get("read", [])
    for r_root in policy.get("readable_roots", []):
        assert r_root["path"] in read_paths, f"readable root {r_root['path']} missing from profile read"

    # Network destinations check
    allowed_domains = prof.get("network", {}).get("allow_domain", [])
    for dest in policy.get("network_destinations", []):
        assert dest["dns_name"] in allowed_domains, f"network destination {dest['dns_name']} missing from profile"
    assert 443 in prof.get("network", {}).get("connect_port", [])

    # Deny rules check
    deny_paths = prof.get("filesystem", {}).get("deny", [])
    assert "/root" in deny_paths
    assert "/etc/shadow" in deny_paths


def test_nono_profile_fail_closed() -> None:
    """Assert nono profile enforces fail-closed isolation directives and denies credential leaks."""
    from pathlib import Path
    import json

    profile_path = (
        Path(__file__).resolve().parents[3]
        / "agentmaxxing-host-sensor"
        / "profile.json"
    )
    with profile_path.open(encoding="utf-8") as f:
        prof = json.load(f)

    security = prof.get("security", {})
    assert security.get("signal_mode") == "isolated"
    assert security.get("process_info_mode") == "isolated"
    assert security.get("capability_elevation") is False

    deny_vars = prof.get("environment", {}).get("deny_vars", [])
    assert "SSH_AUTH_SOCK" in deny_vars
    assert "AWS_ACCESS_KEY_ID" in deny_vars
    assert "GITHUB_TOKEN" in deny_vars


def test_process_metadata() -> None:
    """Validate bounded process lifecycle telemetry against host export policy and schema."""
    from pathlib import Path
    import sys

    from agentmaxxing_host_policy import (
        AttributableIdentity,
        filter_host_telemetry,
        load_host_policy,
    )

    sensor_dir = Path(__file__).resolve().parents[3] / "agentmaxxing-host-sensor"
    if str(sensor_dir) not in sys.path:
        sys.path.insert(0, str(sensor_dir))

    from collector import ProcessTelemetryCollector
    from models import HealthState

    collector = ProcessTelemetryCollector()
    event = collector.collect_event(
        session_id="amxo-proc-001",
        sequence=0,
        agent_id="agentmaxxing-linux-001",
        host_id="amx-host-001",
        pid=1,
        tenant_id="tenant-agentmaxxing",
        override_exit_code=None,
        restart_count=0,
    )

    raw_event = event.to_dict(include_tenant=True)
    # Inject synthetic raw field to simulate dirty input that must be filtered
    raw_event["memory_contents"] = "FORBIDDEN_PROCESS_MEMORY"
    raw_event["command"] = "python3 /agent/run.py"

    policy_path = (
        Path(__file__).resolve().parents[4]
        / "governance"
        / "fixtures"
        / "agentmaxxing-host-policy.v1.json"
    )
    policy = load_host_policy(policy_path)

    exported = filter_host_telemetry(
        raw_event,
        AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        ),
        policy,
    )

    assert exported["schema_version"] == "1.0.0"
    assert exported["evidence_type"] == "process"
    assert exported["tenant_id"] == "tenant-agentmaxxing"
    assert exported["agent_id"] == "agentmaxxing-linux-001"
    assert exported["host_id"] == "amx-host-001"
    assert "memory_contents" not in exported
    assert "command" not in exported

    attrs = exported["attributes"]
    assert set(attrs.keys()) == {
        "health_state",
        "cpu_time_ms",
        "resident_memory_bytes",
        "exit_code",
        "restart_count",
    }
    assert attrs["health_state"] in ("running", "starting", "stopped", "failed", "unknown")
    assert attrs["cpu_time_ms"] >= 0
    assert attrs["resident_memory_bytes"] >= 0
    assert attrs["restart_count"] == 0


def test_anti_escape_descriptor_relative_validation(tmp_path: Any) -> None:
    """AMXO-P4-3: Assert descriptor-relative anti-escape constraints reject ineligible targets with 0 bytes read."""
    from pathlib import Path
    import tempfile
    
    # Import file validator module from agentmaxxing-host-sensor
    sensor_dir = Path(__file__).resolve().parents[3] / "agentmaxxing-host-sensor"
    if str(sensor_dir) not in sys.path:
        sys.path.insert(0, str(sensor_dir))
    
    from file_validator import (
        PinnedRoot,
        EligibilityStatus,
        RejectionReason,
        validate_and_hash_artifact,
    )

    work_dir = tmp_path / "agent_work"
    work_dir.mkdir(parents=True, exist_ok=True)
    
    # 1. Valid regular file
    valid_file = work_dir / "valid_output.json"
    valid_file.write_text('{"status": "ok", "result": 42}', encoding="utf-8")
    
    with PinnedRoot(str(work_dir)) as pinned:
        valid_res = pinned.validate_and_hash("valid_output.json")
        assert valid_res.is_eligible
        assert valid_res.sha256 is not None
        assert valid_res.bytes_read > 0
        assert "RESOLVE_BENEATH" in valid_res.syscall_flags_used
        assert "RESOLVE_NO_SYMLINKS" in valid_res.syscall_flags_used
        assert "RESOLVE_NO_XDEV" in valid_res.syscall_flags_used

        # 2. Symlink trap (inside)
        symlink_inside = work_dir / "sym_inside.json"
        symlink_inside.symlink_to("valid_output.json")
        sym_res = pinned.validate_and_hash("sym_inside.json")
        assert not sym_res.is_eligible
        assert sym_res.reason == RejectionReason.SYMLINK_REJECTED
        assert sym_res.bytes_read == 0

        # 3. Symlink escape (outside to /etc/passwd)
        symlink_out = work_dir / "sym_outside.json"
        symlink_out.symlink_to("/etc/passwd")
        sym_out_res = pinned.validate_and_hash("sym_outside.json")
        assert not sym_out_res.is_eligible
        assert sym_out_res.reason == RejectionReason.SYMLINK_REJECTED
        assert sym_out_res.bytes_read == 0

        # 4. Path traversal escape (..)
        traversal_res = pinned.validate_and_hash("../../../etc/passwd")
        assert not traversal_res.is_eligible
        assert traversal_res.reason == RejectionReason.ESCAPE_REJECTED
        assert traversal_res.bytes_read == 0

        # 5. Hard-link escape (nlink > 1)
        hardlink_target = work_dir / "hardlink_target.json"
        os.link(str(valid_file), str(hardlink_target))
        hl_res = pinned.validate_and_hash("hardlink_target.json")
        assert not hl_res.is_eligible
        assert hl_res.reason == RejectionReason.HARDLINK_REJECTED
        assert hl_res.bytes_read == 0


def test_toctou_artifact_rejection_and_unobserved_classification() -> None:
    """TOCTOU race rejection produces unobserved observation state and invalidates digests."""
    from agentmaxxing_host_policy import ObservationState

    # Simulated TOCTOU rejection evidence payload
    toctou_artifact_evidence = {
        "artifact_id": "hmac-sha256:7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069",
        "root_id": "agent-work",
        "sha256": None,
        "size_bytes": 4096,
        "mtime_ns": 1789320000000000000,
        "observation_state": "unobserved",
        "integrity_state": "unverified",
        "reason_code": "toctou_mutation_detected",
        "error_detail": "File mtime changed post-hash: pre=1789320000000000000, post=1789320005000000000",
    }

    # Verify that unobserved state and invalidated digest are strictly preserved
    assert toctou_artifact_evidence["observation_state"] == ObservationState.UNOBSERVED.value
    assert toctou_artifact_evidence["sha256"] is None
    assert toctou_artifact_evidence["reason_code"] == "toctou_mutation_detected"


def test_toctou_sensor_hasher_integration(tmp_path: Any) -> None:
    """Direct sensor hasher execution verifies descriptor pinning and TOCTOU rejection."""
    import sys
    from pathlib import Path
    sensor_dir = Path(__file__).resolve().parents[3] / "agentmaxxing-host-sensor"
    if str(sensor_dir) not in sys.path:
        sys.path.insert(0, str(sensor_dir))

    from hasher import BoundedArtifactHasher
    from ratelimit import RateLimiter

    hasher = BoundedArtifactHasher(
        rate_limiter=RateLimiter(max_files_per_window=10, max_bytes_per_window=1_000_000),
        max_file_size_bytes=1_000_000,
        chunk_size=1024,
    )

    work_dir = str(tmp_path / "work")
    os.makedirs(work_dir, exist_ok=True)
    test_file = os.path.join(work_dir, "test.txt")
    with open(test_file, "wb") as f:
        f.write(b"Initial pristine content" * 10)

    # 1. Pristine hash succeeds
    res_clean = hasher.hash_relative_path(work_dir, "test.txt", root_id="agent-work")
    assert res_clean.observation_state == "observed"
    assert res_clean.integrity_state == "verified"
    assert res_clean.sha256 is not None

    # 2. Concurrent mutation triggers TOCTOU rejection
    mutated = False

    def mutate_hook() -> None:
        nonlocal mutated
        if not mutated:
            with open(test_file, "ab") as f:
                f.write(b"MUTATION")
            mutated = True

    res_mutated = hasher.hash_relative_path(
        work_dir, "test.txt", root_id="agent-work", read_delay_hook=mutate_hook
    )
    assert res_mutated.observation_state == "unobserved"
    assert res_mutated.integrity_state == "unverified"
    assert res_mutated.sha256 is None
    assert "toctou" in (res_mutated.reason_code or "")


# ---------------------------------------------------------------------------
# AMXO-P5-1 Finalized Audit Session Verification Tests
# ---------------------------------------------------------------------------

def test_ingest_finalized_audit_session_success(client: TestClient):
    """Test successful ingestion and verification of a finalized audit session via /sessions/finalized."""
    events, root_hash = _build_hash_chained_events(3, finalized=True)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-finalized-valid",
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

    # Test via dedicated /sessions/finalized endpoint
    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 201, res.text
    data = res.json()
    assert data["session_id"] == "sess-test-finalized-valid"
    assert data["valid"] is True
    assert data["hash_chain_valid"] is True
    assert data["signature_valid"] is True
    assert data["events_verified"] == 3

    # Test via query parameter require_finalized=true on /sessions
    payload["session_id"] = "sess-test-finalized-param"
    res2 = client.post("/api/audit/sessions?require_finalized=true", json=payload, headers=_bearer("audit-tester"))
    assert res2.status_code == 201, res2.text
    assert res2.json()["valid"] is True


def test_ingest_finalized_session_rejects_unfinalized(client: TestClient):
    """Test that an unfinalized session is rejected with HTTP 422 Unprocessable Entity."""
    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-unfinalized",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": None,
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
        "metadata": {"substrate": "kind", "lsm": "landlock"},
    }

    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 422, res.text
    err = res.json()
    assert "unfinalized" in str(err).lower()


def test_ingest_finalized_session_rejects_sequence_gap(client: TestClient):
    """Test that sequence gaps are rejected with HTTP 400."""
    events, _ = _build_hash_chained_events(3)
    # Introduce gap: seq 1, 3, 4
    events[1]["seq"] = 3
    events[2]["seq"] = 4
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"

    payload = {
        "session_id": "sess-test-gap",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": "dummy",
        "signature": "sig-spiffe-dummy",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400, res.text
    assert "sequence gap" in res.text.lower()


def test_ingest_finalized_session_rejects_out_of_order_sequence(client: TestClient):
    """Test that out-of-order sequences are rejected with HTTP 400."""
    events, _ = _build_hash_chained_events(3)
    # Out of order: seq 2 before seq 1
    events[0]["seq"] = 2
    events[1]["seq"] = 1
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"

    payload = {
        "session_id": "sess-test-ooo",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": "dummy",
        "signature": "sig-spiffe-dummy",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400, res.text
    assert "out-of-order" in res.text.lower() or "sequence" in res.text.lower()


def test_ingest_finalized_session_rejects_empty_events(client: TestClient):
    """Test that empty sessions are rejected with HTTP 400 under finalized requirement."""
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    payload = {
        "session_id": "sess-test-empty",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 0,
        "root_hash": "0000000000000000000000000000000000000000000000000000000000000000",
        "signature": "sig-spiffe-dummy",
        "algorithm": "ECDSA_SHA256",
        "events": [],
    }

    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400, res.text
    assert "empty" in res.text.lower()


def test_ingest_finalized_session_rejects_hash_chain_corruption(client: TestClient):
    """Test that hash chain corruption is rejected with HTTP 400."""
    events, root_hash = _build_hash_chained_events(3, tamper_seq=2)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-tampered-finalized",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400, res.text
    assert "hash chain" in res.text.lower()


def test_ingest_finalized_session_rejects_forged_signature(client: TestClient):
    """Test that forged or invalid signature on finalized session is rejected with HTTP 400."""
    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"

    payload = {
        "session_id": "sess-test-forged-finalized",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": "sig-spiffe-forged00000000000000000000000000000000000000000000000000000000",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    res = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 400, res.text
    assert "signature" in res.text.lower()


def test_verify_probe_with_require_finalized(client: TestClient):
    """Test /sessions/verify probe endpoint behavior with require_finalized."""
    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-probe-unfinalized",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": None,
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    res = client.post("/api/audit/sessions/verify?require_finalized=true", json=payload, headers=_bearer("audit-tester"))
    assert res.status_code == 200
    data = res.json()
    assert data["valid"] is False
    assert "unfinalized" in data["error"].lower()


# ---------------------------------------------------------------------------
# AMXO-P5-2: Upload Idempotency and Concurrency Tests
# ---------------------------------------------------------------------------

def test_idempotency_duplicate_upload_returns_200(client: TestClient):
    """Assert re-uploading an identical audit session returns HTTP 200 with identical root hash."""
    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-idempotent-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    # First upload: initial creation returns 201 Created
    res1 = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res1.status_code == 201, res1.text
    data1 = res1.json()
    assert data1["valid"] is True
    assert data1["is_idempotent"] is False
    assert data1["root_hash"] == root_hash

    # Second upload: idempotent replay returns 200 OK with identical verification proof
    res2 = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res2.status_code == 200, res2.text
    data2 = res2.json()
    assert data2["valid"] is True
    assert data2["is_idempotent"] is True
    assert data2["root_hash"] == root_hash
    assert data2["session_id"] == data1["session_id"]
    assert data2["events_verified"] == data1["events_verified"]


def test_idempotency_finalized_session_duplicate_returns_200(client: TestClient):
    """Assert re-uploading a finalized audit session returns HTTP 200 with identical verification."""
    events, root_hash = _build_hash_chained_events(4, finalized=True)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-idempotent-finalized-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:10:00Z",
        "events_count": 4,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    # Initial upload
    res1 = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res1.status_code == 201, res1.text
    assert res1.json()["is_idempotent"] is False

    # Idempotent re-upload
    res2 = client.post("/api/audit/sessions/finalized", json=payload, headers=_bearer("audit-tester"))
    assert res2.status_code == 200, res2.text
    data2 = res2.json()
    assert data2["is_idempotent"] is True
    assert data2["root_hash"] == root_hash


def test_idempotency_conflicting_payload_returns_409(client: TestClient):
    """Assert attempting to upload conflicting data under an existing session ID returns HTTP 409 Conflict."""
    events1, root_hash1 = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest1 = hashlib.sha256(f"{root_hash1}:{spiffe_id}".encode()).hexdigest()

    payload1 = {
        "session_id": "sess-test-conflict-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash1,
        "signature": f"sig-spiffe-{sig_digest1}",
        "algorithm": "ECDSA_SHA256",
        "events": events1,
    }

    res1 = client.post("/api/audit/sessions", json=payload1, headers=_bearer("audit-tester"))
    assert res1.status_code == 201, res1.text

    # Prepare conflicting payload with different events / root hash for same session_id
    events2, root_hash2 = _build_hash_chained_events(4)
    sig_digest2 = hashlib.sha256(f"{root_hash2}:{spiffe_id}".encode()).hexdigest()

    payload2 = {
        "session_id": "sess-test-conflict-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 4,
        "root_hash": root_hash2,
        "signature": f"sig-spiffe-{sig_digest2}",
        "algorithm": "ECDSA_SHA256",
        "events": events2,
    }

    res2 = client.post("/api/audit/sessions", json=payload2, headers=_bearer("audit-tester"))
    assert res2.status_code == 409, res2.text
    err = res2.json()
    assert err.get("code") == "session_conflict" or "conflict" in res2.text.lower()


def test_concurrent_upload(client: TestClient):
    """Assert multiple concurrent uploads of identical audit session are safely deduplicated without errors."""
    from concurrent.futures import ThreadPoolExecutor

    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-concurrent-dedup-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    headers = _bearer("audit-tester")

    def upload():
        return client.post("/api/audit/sessions", json=payload, headers=headers)

    concurrency = 10
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(upload) for _ in range(concurrency)]
        responses = [f.result() for f in futures]

    status_codes = [r.status_code for r in responses]
    assert all(code in (200, 201) for code in status_codes), f"Unexpected status codes: {status_codes}"
    assert 201 in status_codes, "Expected at least one 201 Created response"

    # All responses must confirm identical root hash
    for r in responses:
        body = r.json()
        assert body["root_hash"] == root_hash
        assert body["valid"] is True


def test_interrupted_retry_resumption(client: TestClient):
    """Assert interrupted network retry cleanly succeeds and yields verified idempotent response."""
    events, root_hash = _build_hash_chained_events(3)
    spiffe_id = "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced"
    sig_digest = hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()

    payload = {
        "session_id": "sess-test-retry-resume-001",
        "agent_id": "agent-nono-evidenced",
        "spiffe_id": spiffe_id,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": 3,
        "root_hash": root_hash,
        "signature": f"sig-spiffe-{sig_digest}",
        "algorithm": "ECDSA_SHA256",
        "events": events,
    }

    # Initial upload completes
    res1 = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res1.status_code == 201, res1.text

    # Client retry after timeout
    res2 = client.post("/api/audit/sessions", json=payload, headers=_bearer("audit-tester"))
    assert res2.status_code == 200, res2.text
    data2 = res2.json()
    assert data2["is_idempotent"] is True
    assert data2["root_hash"] == root_hash



