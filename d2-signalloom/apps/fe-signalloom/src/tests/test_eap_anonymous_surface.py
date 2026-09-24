"""Probe for anonymous EAP attack surface on merged integration tip.

This test module acts as an audit probe across every operation mounted by the
five EAP routers:
  1. tenant_isolation.py (/api/v1/eap/tenants)
  2. scenario_seeding.py (/api/v1/eap/scenarios)
  3. environment_routing.py (/api/v1/environments)
  4. environment_lifecycle.py (/api/v1/eap/lifecycle)
  5. webhook_triggers.py (/api/v1/webhooks)

In Phase 2 Preflight (EAPR-P2-PRE), this probe records the unauthenticated baseline
status of all endpoints. In Phase 2 Step 1 (EAPR-P2-1), it will be converted into
a strict default-deny assertion (asserting 401 on every unauthenticated request).
"""

import base64
import json
from types import SimpleNamespace
from typing import Any, Dict, List, Tuple

import pytest
from fastapi.routing import APIRoute, APIWebSocketRoute
from fastapi.testclient import TestClient

from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

CUSTOMER_HASH = "6f82ad81"
COMPANY_NAME = "kurasi"
SLET_SPIFFE_TRUST_DOMAIN = "osramp.local"
TENANT_SPIFFE_ID = f"spiffe://{SLET_SPIFFE_TRUST_DOMAIN}/ns/eap-{CUSTOMER_HASH}/sa/tenant-app"

EAP_PREFIXES = (
    "/api/v1/eap/tenants",
    "/api/v1/eap/scenarios",
    "/api/v1/environments",
    "/api/v1/eap/lifecycle",
    "/api/v1/webhooks",
)

BODIES: Dict[Tuple[str, str], Dict[str, Any]] = {
    ("POST", "/api/v1/environments/provision"): {
        "company_name": COMPANY_NAME,
        "tier": "demo",
        "ttl_minutes": 60,
    },
    ("POST", "/api/v1/environments/resolve-domain"): {
        "customer_hash": CUSTOMER_HASH,
    },
    ("POST", "/api/v1/environments/{environment_id}/extend"): {
        "additional_minutes": 30,
    },
    ("POST", "/api/v1/environments/{environment_id}/teardown"): {
        "reason": "anonymous-surface-probe",
    },
    ("POST", "/api/v1/eap/tenants"): {
        "company_name": COMPANY_NAME,
        "customer_hash": CUSTOMER_HASH,
    },
    ("POST", "/api/v1/eap/tenants/{customer_hash}/transit/encrypt"): {
        "plaintext": base64.b64encode(b"probe-plaintext-payload").decode("ascii"),
    },
    ("POST", "/api/v1/eap/tenants/{customer_hash}/transit/decrypt"): {
        "ciphertext": "vault:v1:placeholder",
    },
    ("POST", "/api/v1/eap/scenarios/execute"): {
        "scenario_type": "baseline_agent_flow",
        "company_name": COMPANY_NAME,
        "customer_hash": CUSTOMER_HASH,
    },
    ("POST", "/api/v1/eap/lifecycle/register"): {
        "company_name": COMPANY_NAME,
        "customer_hash": CUSTOMER_HASH,
        "ttl_minutes": 60,
    },
    ("POST", "/api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat"): {
        "extend_minutes": 30,
    },
    ("POST", "/api/v1/eap/lifecycle/environments/{customer_hash}/activity"): {},
    ("POST", "/api/v1/eap/lifecycle/reap-now"): {},
    ("POST", "/api/v1/eap/lifecycle/reaper/pause"): {},
    ("POST", "/api/v1/eap/lifecycle/reaper/resume"): {},
    ("POST", "/api/v1/eap/lifecycle/reaper/dlq/clear"): {},
    ("POST", "/api/v1/webhooks/generic"): {},
    ("POST", "/api/v1/webhooks/github"): {
        "repository": {"name": "kurasi"},
        "action": "opened",
        "number": 1,
    },
}


@pytest.fixture
def probe_client(monkeypatch):
    """TestClient setup with test pool and settings without invoking background reaper."""
    settings.api_jwt_issuer = "https://issuer.test"
    settings.api_jwt_audience = "signalloom-api"
    settings.api_jwt_authorized_party = "signalloom-dashboard"
    settings.api_jwks_url = "https://issuer.test/keys"
    settings.api_subject_tenants = {"demo-user": "tenant-demo"}
    settings.api_superadmin_emails = set()
    settings.api_superadmin_subjects = set()

    async def _noop_close() -> None:
        return None

    set_pool_for_testing(SimpleNamespace(close=_noop_close))
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


def test_positive_control_protected_route_refuses_anonymous(probe_client: TestClient) -> None:
    """Verify that the test harness properly enforces 401 on an authenticated route."""
    resp = probe_client.get("/api/agents/claim")
    assert resp.status_code == 401, (
        f"Expected 401 on protected route /api/agents/claim without token, got {resp.status_code}"
    )
    assert resp.json().get("error", {}).get("code") == "authentication_required"


def test_forged_x_spiffe_id_refused_without_bearer(probe_client: TestClient) -> None:
    """Verify forged X-SPIFFE-ID header is refused with 401 without valid bearer token."""
    # Encrypt attempt with forged header without bearer token must return 401
    enc_res = probe_client.post(
        f"/api/v1/eap/tenants/{CUSTOMER_HASH}/transit/encrypt",
        json={"plaintext": base64.b64encode(b"confidential-data").decode("ascii")},
        headers={"X-SPIFFE-ID": TENANT_SPIFFE_ID},
    )
    assert enc_res.status_code == 401, f"Expected 401, got {enc_res.status_code}: {enc_res.text}"
    assert enc_res.json().get("error", {}).get("code") == "authentication_required"

    # Decrypt attempt with forged header without bearer token must return 401
    dec_res = probe_client.post(
        f"/api/v1/eap/tenants/{CUSTOMER_HASH}/transit/decrypt",
        json={"ciphertext": "vault:v1:test"},
        headers={"X-SPIFFE-ID": TENANT_SPIFFE_ID},
    )
    assert dec_res.status_code == 401, f"Expected 401, got {dec_res.status_code}: {dec_res.text}"
    assert dec_res.json().get("error", {}).get("code") == "authentication_required"


def test_enumerate_eap_anonymous_surface(probe_client: TestClient) -> None:
    """Enumerate all 35 EAP operations and log their anonymous accessibility."""
    # Seed resources so dynamic paths exist
    r_env = probe_client.post(
        "/api/v1/environments/provision",
        json={"company_name": COMPANY_NAME, "tier": "demo", "ttl_minutes": 60},
    )
    env_id = r_env.json().get("id", f"eap-{CUSTOMER_HASH}")

    probe_client.post(
        "/api/v1/eap/tenants",
        json={"company_name": COMPANY_NAME, "customer_hash": CUSTOMER_HASH},
    )
    probe_client.post(
        "/api/v1/eap/lifecycle/register",
        json={"company_name": COMPANY_NAME, "customer_hash": CUSTOMER_HASH, "ttl_minutes": 60},
    )
    probe_client.post(
        "/api/v1/eap/scenarios/execute",
        json={
            "scenario_type": "baseline_agent_flow",
            "company_name": COMPANY_NAME,
            "customer_hash": CUSTOMER_HASH,
        },
    )

    enc_res = probe_client.post(
        f"/api/v1/eap/tenants/{CUSTOMER_HASH}/transit/encrypt",
        json={"plaintext": base64.b64encode(b"payload").decode("ascii")},
        headers={"X-SPIFFE-ID": TENANT_SPIFFE_ID},
    )
    ciphertext = enc_res.json().get("ciphertext", "vault:v1:test")

    probe_results: List[Tuple[str, str, int, str, str]] = []

    for r in app.routes:
        if isinstance(r, APIRoute):
            for prefix in EAP_PREFIXES:
                if r.path.startswith(prefix):
                    for m in r.methods:
                        if m in ("HEAD", "OPTIONS"):
                            continue
                        call_path = r.path.replace("{customer_hash}", CUSTOMER_HASH).replace(
                            "{environment_id}", env_id
                        )
                        body = BODIES.get((m, r.path))
                        if r.path == "/api/v1/eap/scenarios/events/{customer_hash}/stream":
                            resp = probe_client.get(call_path, params={"limit": 1})
                            status = resp.status_code
                            note = f"SSE ({resp.headers.get('content-type', '')})"
                        elif m == "GET":
                            resp = probe_client.get(call_path)
                            status = resp.status_code
                            note = f"bytes={len(resp.content)}"
                        elif m == "POST":
                            if r.path == "/api/v1/eap/tenants/{customer_hash}/transit/decrypt":
                                body = {"ciphertext": ciphertext}
                            resp = probe_client.post(call_path, json=body if body is not None else {})
                            status = resp.status_code
                            note = f"resp={resp.status_code}"
                        elif m == "DELETE":
                            resp = probe_client.delete(call_path)
                            status = resp.status_code
                            note = f"resp={resp.status_code}"
                        elif m == "PUT":
                            resp = probe_client.put(call_path, json=body if body is not None else {})
                            status = resp.status_code
                            note = f"resp={resp.status_code}"

                        probe_results.append((m, r.path, status, f"{r.endpoint.__module__}:{r.endpoint.__name__}", note))
        elif isinstance(r, APIWebSocketRoute):
            for prefix in EAP_PREFIXES:
                if r.path.startswith(prefix):
                    call_path = r.path.replace("{customer_hash}", CUSTOMER_HASH).replace(
                        "{environment_id}", env_id
                    )
                    try:
                        with probe_client.websocket_connect(call_path) as ws:
                            msg = ws.receive_json()
                            status = 200
                            note = f"WS accepted (event={msg.get('event')})"
                    except Exception as exc:
                        status = 403
                        note = f"WS refused ({exc})"
                    probe_results.append((
                        "WS",
                        r.path,
                        status,
                        f"{r.endpoint.__module__}:{r.endpoint.__name__}",
                        note,
                    ))

    print(f"\nTotal probed EAP operations: {len(probe_results)}")
    print(f"{'METHOD':6} | {'ROUTE PATH':55} | {'STATUS':6} | {'MODULE:HANDLER':45} | NOTES")
    print("=" * 130)
    for m, p, status, handler, note in sorted(probe_results, key=lambda x: (x[3].split(":")[0], x[1])):
        print(f"{m:6} | {p:55} | {status:6} | {handler:45} | {note}")

    assert len(probe_results) == 35, f"Expected 35 probed operations, found {len(probe_results)}"
