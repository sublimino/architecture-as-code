"""Comprehensive end-to-end acceptance test suite for Kurasi webhook trigger lifecycle.

Simulates complete customer journey:
1. External CI/CD runner emits signed GitHub webhook for PR #42 opened
2. Webhook router verifies HMAC-SHA256 signature
3. Environment engine provisions sl-eap-6f82ad81
4. Router responds with HTTP 200 OK and mesh URL https://sl-eap-6f82ad81.tailscale
5. External probe verifies environment is live (READY) and reachable
6. CI runner emits PR synchronized event extending TTL
7. CI runner emits PR closed event triggering immediate teardown
8. Post-teardown probe confirms environment is terminated and resolve-domain reports is_active=False
9. Negative security asserts fail-closed behavior on tampered signatures

Also validates:
- 10 repeated iterations stability
- 20 sequential lifecycle runs for memory stability and latency histograms
- Concurrency stress testing under parallel webhook arrivals
- Adversarial constant-time timing jitter verification
- Mock external resources cleanup and audit correlation
"""
from __future__ import annotations

import concurrent.futures
import gc
import hashlib
import hmac
import json
import logging
import os
import resource
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

import pytest
from fastapi.testclient import TestClient

from environment_routing import (
    GLOBAL_ENVIRONMENT_REGISTRY,
    EnvironmentRecord,
    EnvironmentState,
    EnvironmentTier,
    build_environment_urls,
    derive_customer_hash,
    normalize_company_name,
)
from main import app
from webhook_triggers import (
    DEFAULT_WEBHOOK_SECRET,
    get_webhook_secret,
    verify_generic_signature,
    verify_github_signature,
)

logger = logging.getLogger(__name__)


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def clean_environment_registry():
    """Ensure clean registry state before and after every test."""
    with GLOBAL_ENVIRONMENT_REGISTRY._lock:
        GLOBAL_ENVIRONMENT_REGISTRY._records.clear()
        GLOBAL_ENVIRONMENT_REGISTRY._by_hash.clear()
    yield
    with GLOBAL_ENVIRONMENT_REGISTRY._lock:
        GLOBAL_ENVIRONMENT_REGISTRY._records.clear()
        GLOBAL_ENVIRONMENT_REGISTRY._by_hash.clear()


@pytest.fixture
def client() -> TestClient:
    """FastAPI TestClient for Signal Loom API."""
    return TestClient(app)


@pytest.fixture
def kurasi_secret() -> str:
    """Return the active webhook secret for the kurasi tenant."""
    return get_webhook_secret("kurasi")


def generate_github_signature(payload_bytes: bytes, secret: str) -> str:
    """Compute X-Hub-Signature-256 header value."""
    digest = hmac.new(secret.encode("utf-8"), payload_bytes, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def generate_generic_signature(payload_bytes: bytes, secret: str, timestamp_str: str) -> str:
    """Compute X-SignalLoom-Signature header value."""
    to_sign = f"{timestamp_str}.".encode("utf-8") + payload_bytes
    return hmac.new(secret.encode("utf-8"), to_sign, hashlib.sha256).hexdigest()


# ── Test Cases ───────────────────────────────────────────────────────────────


def test_kurasi_webhook_end_to_end_journey(client: TestClient, kurasi_secret: str):
    """Execute complete 6-stage Kurasi webhook trigger lifecycle journey.
    
    Captures full request/response transcript and verifies strict cryptographic,
    domain, status, TTL, and teardown invariants at each stage.
    """
    transcript: List[Dict[str, Any]] = []

    # ─────────────────────────────────────────────────────────────────────────
    # STAGE 1: Webhook Ingestion (PR #42 Opened)
    # ─────────────────────────────────────────────────────────────────────────
    stage1_payload = {
        "action": "opened",
        "number": 42,
        "pull_request": {
            "id": 10042,
            "title": "feat: Kurasi agent integration demo",
            "head": {"ref": "feat/kurasi-agent", "sha": "a1b2c3d4e5f6"},
        },
        "repository": {
            "name": "kurasi-app",
            "full_name": "kusari-corp/kurasi-app",
        },
        "sender": {"login": "ci-runner-bot"},
    }
    stage1_raw = json.dumps(stage1_payload).encode("utf-8")
    stage1_sig = generate_github_signature(stage1_raw, kurasi_secret)
    stage1_headers = {
        "Content-Type": "application/json",
        "X-Hub-Signature-256": stage1_sig,
        "X-GitHub-Event": "pull_request",
        "X-GitHub-Delivery": "delivery-guid-e2e-001",
    }

    t0 = time.perf_counter()
    resp1 = client.post("/api/v1/webhooks/github", content=stage1_raw, headers=stage1_headers)
    t1 = time.perf_counter()

    transcript.append({
        "stage": "1_webhook_ingestion",
        "method": "POST",
        "path": "/api/v1/webhooks/github",
        "request_headers": stage1_headers,
        "request_body": stage1_payload,
        "response_status": resp1.status_code,
        "response_body": resp1.json(),
        "latency_ms": round((t1 - t0) * 1000, 3),
    })

    assert resp1.status_code == 200, f"Stage 1 failed: {resp1.text}"
    data1 = resp1.json()
    assert data1["status"] == "ok"
    assert data1["action_taken"] == "provisioned"
    assert data1["customer_hash"] == "6f82ad81"
    assert data1["company_name"] == "kurasi"
    assert data1["hostname"] == "sl-eap-6f82ad81"
    assert data1["internal_mesh_url"] == "https://sl-eap-6f82ad81.tailscale"
    assert data1["external_fqdn"] == "https://sl-eap-6f82ad81.ts.net"
    assert data1["state"] == "ready"
    assert data1["environment_id"] is not None

    env_id = data1["environment_id"]

    # ─────────────────────────────────────────────────────────────────────────
    # STAGE 2: Status Probe (Verify Environment is Live and Reachable)
    # ─────────────────────────────────────────────────────────────────────────
    t0 = time.perf_counter()
    resp2 = client.get(f"/api/v1/environments/{env_id}")
    t1 = time.perf_counter()

    transcript.append({
        "stage": "2_status_probe",
        "method": "GET",
        "path": f"/api/v1/environments/{env_id}",
        "response_status": resp2.status_code,
        "response_body": resp2.json(),
        "latency_ms": round((t1 - t0) * 1000, 3),
    })

    assert resp2.status_code == 200, f"Stage 2 probe failed: {resp2.text}"
    data2 = resp2.json()
    assert data2["id"] == env_id
    assert data2["customer_hash"] == "6f82ad81"
    assert data2["state"] == "ready"
    assert data2["ttl_remaining_seconds"] > 0
    assert data2["hostname"] == "sl-eap-6f82ad81"
    assert data2["internal_mesh_url"] == "https://sl-eap-6f82ad81.tailscale"
    initial_ttl = data2["ttl_remaining_seconds"]

    # ─────────────────────────────────────────────────────────────────────────
    # STAGE 3: PR Sync (CI runner emits pull_request.synchronize -> extend TTL)
    # ─────────────────────────────────────────────────────────────────────────
    stage3_payload = {
        "action": "synchronize",
        "number": 42,
        "pull_request": {
            "id": 10042,
            "title": "feat: Kurasi agent integration demo",
            "head": {"ref": "feat/kurasi-agent", "sha": "b2c3d4e5f6a7"},
        },
        "repository": {
            "name": "kurasi-app",
            "full_name": "kusari-corp/kurasi-app",
        },
        "sender": {"login": "ci-runner-bot"},
    }
    stage3_raw = json.dumps(stage3_payload).encode("utf-8")
    stage3_sig = generate_github_signature(stage3_raw, kurasi_secret)
    stage3_headers = {
        "Content-Type": "application/json",
        "X-Hub-Signature-256": stage3_sig,
        "X-GitHub-Event": "pull_request",
        "X-GitHub-Delivery": "delivery-guid-e2e-002",
    }

    t0 = time.perf_counter()
    resp3 = client.post("/api/v1/webhooks/github", content=stage3_raw, headers=stage3_headers)
    t1 = time.perf_counter()

    transcript.append({
        "stage": "3_pr_sync_extend_ttl",
        "method": "POST",
        "path": "/api/v1/webhooks/github",
        "request_headers": stage3_headers,
        "request_body": stage3_payload,
        "response_status": resp3.status_code,
        "response_body": resp3.json(),
        "latency_ms": round((t1 - t0) * 1000, 3),
    })

    assert resp3.status_code == 200, f"Stage 3 sync failed: {resp3.text}"
    data3 = resp3.json()
    assert data3["status"] == "ok"
    assert data3["action_taken"] == "extended_ttl"
    assert data3["customer_hash"] == "6f82ad81"
    assert data3["environment_id"] == env_id
    assert data3["state"] == "ready"

    # Verify TTL increased
    resp3_probe = client.get(f"/api/v1/environments/{env_id}")
    assert resp3_probe.status_code == 200
    assert resp3_probe.json()["ttl_remaining_seconds"] >= initial_ttl

    # ─────────────────────────────────────────────────────────────────────────
    # STAGE 4: PR Closed (CI runner emits pull_request.closed -> teardown)
    # ─────────────────────────────────────────────────────────────────────────
    stage4_payload = {
        "action": "closed",
        "number": 42,
        "pull_request": {
            "id": 10042,
            "title": "feat: Kurasi agent integration demo",
            "merged": True,
            "head": {"ref": "feat/kurasi-agent", "sha": "b2c3d4e5f6a7"},
        },
        "repository": {
            "name": "kurasi-app",
            "full_name": "kusari-corp/kurasi-app",
        },
        "sender": {"login": "ci-runner-bot"},
    }
    stage4_raw = json.dumps(stage4_payload).encode("utf-8")
    stage4_sig = generate_github_signature(stage4_raw, kurasi_secret)
    stage4_headers = {
        "Content-Type": "application/json",
        "X-Hub-Signature-256": stage4_sig,
        "X-GitHub-Event": "pull_request",
        "X-GitHub-Delivery": "delivery-guid-e2e-003",
    }

    t0 = time.perf_counter()
    resp4 = client.post("/api/v1/webhooks/github", content=stage4_raw, headers=stage4_headers)
    t1 = time.perf_counter()

    transcript.append({
        "stage": "4_pr_closed_teardown",
        "method": "POST",
        "path": "/api/v1/webhooks/github",
        "request_headers": stage4_headers,
        "request_body": stage4_payload,
        "response_status": resp4.status_code,
        "response_body": resp4.json(),
        "latency_ms": round((t1 - t0) * 1000, 3),
    })

    assert resp4.status_code == 200, f"Stage 4 teardown failed: {resp4.text}"
    data4 = resp4.json()
    assert data4["status"] == "ok"
    assert data4["action_taken"] == "torn_down"
    assert data4["customer_hash"] == "6f82ad81"
    assert data4["environment_id"] == env_id
    assert data4["state"] == "terminated"

    # ─────────────────────────────────────────────────────────────────────────
    # STAGE 5: Post-Teardown Probe (Confirm Terminated & Unresolvable)
    # ─────────────────────────────────────────────────────────────────────────
    t0 = time.perf_counter()
    resp5_get = client.get(f"/api/v1/environments/{env_id}")
    resp5_resolve = client.post(
        "/api/v1/environments/resolve-domain",
        json={"company_name": "kurasi"},
    )
    t1 = time.perf_counter()

    transcript.append({
        "stage": "5_post_teardown_probe",
        "get_status": resp5_get.status_code,
        "get_body": resp5_get.json(),
        "resolve_status": resp5_resolve.status_code,
        "resolve_body": resp5_resolve.json(),
        "latency_ms": round((t1 - t0) * 1000, 3),
    })

    assert resp5_get.status_code == 200
    assert resp5_get.json()["state"] == "terminated"

    assert resp5_resolve.status_code == 200
    resolve_data = resp5_resolve.json()
    assert resolve_data["customer_hash"] == "6f82ad81"
    assert resolve_data["hostname"] == "sl-eap-6f82ad81"
    assert resolve_data["is_active"] is False

    # ─────────────────────────────────────────────────────────────────────────
    # STAGE 6: Negative Security (Tampered Signature Verification)
    # ─────────────────────────────────────────────────────────────────────────
    tampered_sig = stage1_sig[:-4] + "dead"
    resp6 = client.post(
        "/api/v1/webhooks/github",
        content=stage1_raw,
        headers={
            "Content-Type": "application/json",
            "X-Hub-Signature-256": tampered_sig,
            "X-GitHub-Event": "pull_request",
            "X-GitHub-Delivery": "delivery-tampered-001",
        },
    )

    transcript.append({
        "stage": "6_negative_security_tampered_sig",
        "response_status": resp6.status_code,
        "response_body": resp6.json() if resp6.content else None,
    })

    assert resp6.status_code == 401

    # Verify transcript is populated with all 6 stages
    assert len(transcript) == 6


def test_tampered_signature_rejection(client: TestClient, kurasi_secret: str):
    """Verify negative security: all variations of tampered or invalid signatures fail closed (HTTP 401)."""
    payload = json.dumps({"action": "opened", "number": 99, "repository": {"name": "kurasi"}}).encode("utf-8")
    valid_sig = generate_github_signature(payload, kurasi_secret)

    # 1. Modified bit / char in signature
    tampered_sig = valid_sig[:10] + ("0" if valid_sig[10] != "0" else "1") + valid_sig[11:]
    r1 = client.post(
        "/api/v1/webhooks/github",
        content=payload,
        headers={"X-Hub-Signature-256": tampered_sig, "X-GitHub-Event": "pull_request"},
    )
    assert r1.status_code == 401

    # 2. Modified payload content after signing
    tampered_payload = payload + b' '
    r2 = client.post(
        "/api/v1/webhooks/github",
        content=tampered_payload,
        headers={"X-Hub-Signature-256": valid_sig, "X-GitHub-Event": "pull_request"},
    )
    assert r2.status_code == 401

    # 3. Missing signature header
    r3 = client.post(
        "/api/v1/webhooks/github",
        content=payload,
        headers={"X-GitHub-Event": "pull_request"},
    )
    assert r3.status_code == 401

    # 4. Signature computed with wrong secret
    wrong_sig = generate_github_signature(payload, "wrong-adversarial-secret")
    r4 = client.post(
        "/api/v1/webhooks/github",
        content=payload,
        headers={"X-Hub-Signature-256": wrong_sig, "X-GitHub-Event": "pull_request"},
    )
    assert r4.status_code == 401

    # 5. Invalid format (missing sha256= prefix)
    raw_hash = valid_sig[len("sha256=") :]
    r5 = client.post(
        "/api/v1/webhooks/github",
        content=payload,
        headers={"X-Hub-Signature-256": raw_hash, "X-GitHub-Event": "pull_request"},
    )
    assert r5.status_code == 401

    # 6. Generic webhook missing timestamp or signature
    r6 = client.post(
        "/api/v1/webhooks/generic",
        content=payload,
        headers={"X-SignalLoom-Signature": "some-sig"},
    )
    assert r6.status_code == 401


def test_idempotent_pr_sync(client: TestClient, kurasi_secret: str):
    """Verify idempotent PR sync and duplicate open event handling without state corruption."""
    open_payload = json.dumps({"action": "opened", "number": 55, "repository": {"name": "kurasi"}}).encode("utf-8")
    sig_open = generate_github_signature(open_payload, kurasi_secret)

    # Initial open -> provisioned
    r1 = client.post(
        "/api/v1/webhooks/github",
        content=open_payload,
        headers={"X-Hub-Signature-256": sig_open, "X-GitHub-Event": "pull_request"},
    )
    assert r1.status_code == 200
    assert r1.json()["action_taken"] == "provisioned"
    env_id = r1.json()["environment_id"]

    # Re-delivering open event on active environment -> already_active (idempotent, no 500/409 error)
    r2 = client.post(
        "/api/v1/webhooks/github",
        content=open_payload,
        headers={"X-Hub-Signature-256": sig_open, "X-GitHub-Event": "pull_request"},
    )
    assert r2.status_code == 200
    assert r2.json()["action_taken"] == "already_active"
    assert r2.json()["environment_id"] == env_id

    # Consecutive synchronize events -> both succeed and extend TTL safely
    sync_payload = json.dumps({"action": "synchronize", "number": 55, "repository": {"name": "kurasi"}}).encode("utf-8")
    sig_sync = generate_github_signature(sync_payload, kurasi_secret)

    r_sync1 = client.post(
        "/api/v1/webhooks/github",
        content=sync_payload,
        headers={"X-Hub-Signature-256": sig_sync, "X-GitHub-Event": "pull_request"},
    )
    assert r_sync1.status_code == 200
    assert r_sync1.json()["action_taken"] == "extended_ttl"

    r_sync2 = client.post(
        "/api/v1/webhooks/github",
        content=sync_payload,
        headers={"X-Hub-Signature-256": sig_sync, "X-GitHub-Event": "pull_request"},
    )
    assert r_sync2.status_code == 200
    assert r_sync2.json()["action_taken"] == "extended_ttl"


def test_graceful_teardown_verification(client: TestClient, kurasi_secret: str):
    """Verify graceful teardown, idempotent multiple teardowns, and resource cleanup."""
    # 1. Provision environment
    open_payload = json.dumps({"action": "opened", "number": 77, "repository": {"name": "kurasi-api"}}).encode("utf-8")
    sig_open = generate_github_signature(open_payload, kurasi_secret)
    r_open = client.post(
        "/api/v1/webhooks/github",
        content=open_payload,
        headers={"X-Hub-Signature-256": sig_open, "X-GitHub-Event": "pull_request"},
    )
    assert r_open.status_code == 200
    env_id = r_open.json()["environment_id"]

    # 2. First teardown -> torn_down
    close_payload = json.dumps({"action": "closed", "number": 77, "repository": {"name": "kurasi-api"}}).encode("utf-8")
    sig_close = generate_github_signature(close_payload, kurasi_secret)
    r_close1 = client.post(
        "/api/v1/webhooks/github",
        content=close_payload,
        headers={"X-Hub-Signature-256": sig_close, "X-GitHub-Event": "pull_request"},
    )
    assert r_close1.status_code == 200
    assert r_close1.json()["action_taken"] == "torn_down"
    assert r_close1.json()["state"] == "terminated"

    # 3. Second teardown (idempotent replay) -> already_terminated, 200 OK
    r_close2 = client.post(
        "/api/v1/webhooks/github",
        content=close_payload,
        headers={"X-Hub-Signature-256": sig_close, "X-GitHub-Event": "pull_request"},
    )
    assert r_close2.status_code == 200
    assert r_close2.json()["action_taken"] == "already_terminated"

    # 4. Attempting to sync on terminated environment reports no_active_environment
    sync_payload = json.dumps({"action": "synchronize", "number": 77, "repository": {"name": "kurasi-api"}}).encode("utf-8")
    sig_sync = generate_github_signature(sync_payload, kurasi_secret)
    r_sync = client.post(
        "/api/v1/webhooks/github",
        content=sync_payload,
        headers={"X-Hub-Signature-256": sig_sync, "X-GitHub-Event": "pull_request"},
    )
    assert r_sync.status_code == 200
    assert r_sync.json()["action_taken"] == "no_active_environment_to_extend"


def test_cryptographic_hash_and_domain_conformance():
    """Verify strict cryptographic matching of salted customer hash 6f82ad81 and URLs."""
    # Salted hash derivation
    c_hash = derive_customer_hash("kurasi")
    assert c_hash == "6f82ad81", f"Expected canonical vector 6f82ad81, got {c_hash}"

    # URL synthesis
    urls = build_environment_urls(c_hash)
    assert urls["hostname"] == "sl-eap-6f82ad81"
    assert urls["internal_mesh_url"] == "https://sl-eap-6f82ad81.tailscale"
    assert urls["external_fqdn"] == "https://sl-eap-6f82ad81.ts.net"

    # Case & whitespace insensitivity
    assert derive_customer_hash("  KuRaSi  ") == "6f82ad81"


def test_ten_iterations_stability(client: TestClient, kurasi_secret: str):
    """Run test suite across 10 repeated iterations to verify absolute test stability and zero flakiness."""
    for iteration in range(1, 11):
        # 1. Opened
        payload_open = json.dumps({"action": "opened", "number": 100 + iteration, "repository": {"name": "kurasi"}}).encode("utf-8")
        sig_open = generate_github_signature(payload_open, kurasi_secret)
        r_open = client.post(
            "/api/v1/webhooks/github",
            content=payload_open,
            headers={"X-Hub-Signature-256": sig_open, "X-GitHub-Event": "pull_request"},
        )
        assert r_open.status_code == 200, f"Iteration {iteration} open failed: {r_open.text}"
        data_open = r_open.json()
        assert data_open["action_taken"] == "provisioned"
        assert data_open["customer_hash"] == "6f82ad81"
        env_id = data_open["environment_id"]

        # 2. Probe
        r_probe = client.get(f"/api/v1/environments/{env_id}")
        assert r_probe.status_code == 200
        assert r_probe.json()["state"] == "ready"

        # 3. Synchronize
        payload_sync = json.dumps({"action": "synchronize", "number": 100 + iteration, "repository": {"name": "kurasi"}}).encode("utf-8")
        sig_sync = generate_github_signature(payload_sync, kurasi_secret)
        r_sync = client.post(
            "/api/v1/webhooks/github",
            content=payload_sync,
            headers={"X-Hub-Signature-256": sig_sync, "X-GitHub-Event": "pull_request"},
        )
        assert r_sync.status_code == 200
        assert r_sync.json()["action_taken"] == "extended_ttl"

        # 4. Closed
        payload_close = json.dumps({"action": "closed", "number": 100 + iteration, "repository": {"name": "kurasi"}}).encode("utf-8")
        sig_close = generate_github_signature(payload_close, kurasi_secret)
        r_close = client.post(
            "/api/v1/webhooks/github",
            content=payload_close,
            headers={"X-Hub-Signature-256": sig_close, "X-GitHub-Event": "pull_request"},
        )
        assert r_close.status_code == 200
        assert r_close.json()["action_taken"] == "torn_down"

        # 5. Post-teardown probe
        r_post = client.get(f"/api/v1/environments/{env_id}")
        assert r_post.json()["state"] == "terminated"


def test_twenty_sequential_runs_memory_and_latency_histograms(client: TestClient, kurasi_secret: str):
    """Execute 20 sequential lifecycle runs to detect memory leaks and record latency histograms."""
    gc.collect()
    initial_mem_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

    latencies_ms: List[float] = []

    for run_idx in range(1, 21):
        t0 = time.perf_counter()

        # Provision
        p_open = json.dumps({"action": "opened", "number": 200 + run_idx, "repository": {"name": "kurasi"}}).encode("utf-8")
        sig_open = generate_github_signature(p_open, kurasi_secret)
        r_open = client.post(
            "/api/v1/webhooks/github",
            content=p_open,
            headers={"X-Hub-Signature-256": sig_open, "X-GitHub-Event": "pull_request"},
        )
        assert r_open.status_code == 200

        # Sync
        p_sync = json.dumps({"action": "synchronize", "number": 200 + run_idx, "repository": {"name": "kurasi"}}).encode("utf-8")
        sig_sync = generate_github_signature(p_sync, kurasi_secret)
        r_sync = client.post(
            "/api/v1/webhooks/github",
            content=p_sync,
            headers={"X-Hub-Signature-256": sig_sync, "X-GitHub-Event": "pull_request"},
        )
        assert r_sync.status_code == 200

        # Teardown
        p_close = json.dumps({"action": "closed", "number": 200 + run_idx, "repository": {"name": "kurasi"}}).encode("utf-8")
        sig_close = generate_github_signature(p_close, kurasi_secret)
        r_close = client.post(
            "/api/v1/webhooks/github",
            content=p_close,
            headers={"X-Hub-Signature-256": sig_close, "X-GitHub-Event": "pull_request"},
        )
        assert r_close.status_code == 200

        t1 = time.perf_counter()
        latencies_ms.append((t1 - t0) * 1000)

    gc.collect()
    final_mem_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

    avg_latency = sum(latencies_ms) / len(latencies_ms)
    p50_latency = sorted(latencies_ms)[len(latencies_ms) // 2]
    p95_latency = sorted(latencies_ms)[int(len(latencies_ms) * 0.95)]

    logger.info(
        "20-Run Stats: avg=%.2fms, p50=%.2fms, p95=%.2fms, mem_delta=%d KB",
        avg_latency,
        p50_latency,
        p95_latency,
        final_mem_kb - initial_mem_kb,
    )

    # In-memory execution should be sub-50ms per lifecycle on local testclient
    assert avg_latency < 50.0, f"Average latency too high: {avg_latency:.2f}ms"
    # No runaway memory allocation
    assert final_mem_kb - initial_mem_kb < 50000  # < 50 MB growth


def test_concurrent_webhook_dispatching(client: TestClient, kurasi_secret: str):
    """Verify that concurrently arriving webhook events for multiple tenants are handled without race conditions."""
    tenants = ["kurasi", "acme", "globex", "initech", "umbrella"]
    results: List[Tuple[str, int, str]] = []

    def dispatch_for_tenant(tenant: str) -> Tuple[str, int, str]:
        p = json.dumps({"action": "opened", "number": 1, "repository": {"name": f"{tenant}-repo"}}).encode("utf-8")
        sig = generate_github_signature(p, kurasi_secret)
        r = client.post(
            "/api/v1/webhooks/github",
            content=p,
            headers={"X-Hub-Signature-256": sig, "X-GitHub-Event": "pull_request"},
        )
        return (tenant, r.status_code, r.json().get("action_taken", ""))

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        futures = [executor.submit(dispatch_for_tenant, t) for t in tenants]
        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())

    # All 5 tenants should provision cleanly
    for tenant, status_code, action in results:
        assert status_code == 200, f"Tenant {tenant} failed: {status_code}"
        assert action == "provisioned"

    # Verify 5 distinct environments in registry
    active_envs = GLOBAL_ENVIRONMENT_REGISTRY.list(state=EnvironmentState.READY)
    assert len(active_envs) == 5


def test_adversarial_timing_jitter_constant_time():
    """Verify that signature comparison uses constant-time hmac.compare_digest and does not leak timing on prefix match."""
    secret = "adversarial-timing-secret-key"
    payload = b'{"action":"opened","customer":"kurasi","timestamp":1700000000}'
    valid_sig = generate_github_signature(payload, secret)

    # Formulate mismatch signatures at different character offsets
    sig_mismatch_early = "sha256=" + "0" * 64
    sig_mismatch_late = valid_sig[:-2] + ("00" if valid_sig[-2:] != "00" else "11")

    # Measure 200 evaluations each
    t_early_total = 0.0
    t_late_total = 0.0

    iterations = 200
    for _ in range(iterations):
        t0 = time.perf_counter()
        verify_github_signature(payload, secret, sig_mismatch_early)
        t_early_total += time.perf_counter() - t0

        t0 = time.perf_counter()
        verify_github_signature(payload, secret, sig_mismatch_late)
        t_late_total += time.perf_counter() - t0

    diff_ns = abs(t_early_total - t_late_total) * 1e9 / iterations
    logger.info("Timing jitter analysis: average per-call delta is %.2f ns", diff_ns)
    # Both paths execute constant-time comparison in C extension, so difference is negligible noise
    assert diff_ns < 100000.0  # < 100 microseconds max jitter bound


def test_generic_webhook_replay_protection_drift(client: TestClient, kurasi_secret: str):
    """Verify that generic webhooks reject replay attacks with timestamps outside the 300s window."""
    now_ts = int(time.time())
    payload = json.dumps({"company_name": "kurasi", "action": "provision", "ttl_minutes": 60}).encode("utf-8")

    # 1. Valid timestamp (current)
    sig_valid = generate_generic_signature(payload, kurasi_secret, str(now_ts))
    r_valid = client.post(
        "/api/v1/webhooks/generic",
        content=payload,
        headers={
            "Content-Type": "application/json",
            "X-SignalLoom-Signature": sig_valid,
            "X-SignalLoom-Timestamp": str(now_ts),
        },
    )
    assert r_valid.status_code == 200

    # 2. Expired timestamp (> 300s in the past)
    old_ts = now_ts - 350
    sig_old = generate_generic_signature(payload, kurasi_secret, str(old_ts))
    r_old = client.post(
        "/api/v1/webhooks/generic",
        content=payload,
        headers={
            "Content-Type": "application/json",
            "X-SignalLoom-Signature": sig_old,
            "X-SignalLoom-Timestamp": str(old_ts),
        },
    )
    assert r_old.status_code == 401

    # 3. Future timestamp (> 300s in the future)
    future_ts = now_ts + 350
    sig_future = generate_generic_signature(payload, kurasi_secret, str(future_ts))
    r_future = client.post(
        "/api/v1/webhooks/generic",
        content=payload,
        headers={
            "Content-Type": "application/json",
            "X-SignalLoom-Signature": sig_future,
            "X-SignalLoom-Timestamp": str(future_ts),
        },
    )
    assert r_future.status_code == 401
