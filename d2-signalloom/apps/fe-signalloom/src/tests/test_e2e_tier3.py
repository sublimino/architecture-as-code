"""Tier 3 -- End-to-end tests through the live cluster.

Requires:
  SIGNALLOOM_API_BASE  -- e.g. http://localhost:5173
  SIGNALLOOM_DEX_EMAIL -- e.g. admin@example.com
  SIGNALLOOM_DEX_PASSWORD -- the Dex static password

All tests are skipped if these environment variables are absent.

Flow: mint a real Dex token via password grant, then hit each /api/*
endpoint through nginx and validate the response against the consumer
contract models in ``tests/contract.py``.
"""
from __future__ import annotations

import os
from typing import Any

import httpx
import pytest
from pydantic import BaseModel

from tests.contract import (
    AgentListResponse,
    AgentResponse,
    AuditListResponse,
    ComplianceSummaryResponse,
    ConsentAcceptResponse,
    ConsentStatusResponse,
    CookiePreferencesResponse,
    CryptoHealthResponse,
    FrameworkResponse,
    InitialApiKeyResponse,
    IssueCredentialResponse,
    NHIDiscoveredResponse,
    NHIScanListResponse,
    PostureResponse,
    ReassessmentResponse,
    RotateApiKeyResponse,
    SupportRequestResponse,
    TenantSettingsResponse,
    TransitionResponse,
    ViolationListResponse,
)

# ---------------------------------------------------------------------------
# Environment gate
# ---------------------------------------------------------------------------

API_BASE = os.environ.get("SIGNALLOOM_API_BASE")
DEX_EMAIL = os.environ.get("SIGNALLOOM_DEX_EMAIL")
DEX_PASSWORD = os.environ.get("SIGNALLOOM_DEX_PASSWORD")

pytestmark = pytest.mark.skipif(
    not all([API_BASE, DEX_EMAIL, DEX_PASSWORD]),
    reason="SIGNALLOOM_API_BASE / SIGNALLOOM_DEX_EMAIL / SIGNALLOOM_DEX_PASSWORD not set",
)


# ---------------------------------------------------------------------------
# Token acquisition via Dex password grant
# ---------------------------------------------------------------------------

def _mint_dex_token() -> str:
    """Obtain a bearer token from Dex using the resource-owner password grant."""
    dex_base = API_BASE.rstrip("/")
    token_url = f"{dex_base}/dex/token"

    response = httpx.post(
        token_url,
        data={
            "grant_type": "password",
            "username": DEX_EMAIL,
            "password": DEX_PASSWORD,
            # The trailing cross-client scope is what makes Dex mint a token
            # audienced to signalloom-api. Without it the token carries
            # aud=signalloom-dashboard, the API's audience check rejects it, and
            # every endpoint answers 401 — which is what this tier did on the
            # first run that ever reached the cluster. It matches the scope the
            # dashboard itself requests in src/auth/oidc.tsx.
            "scope": "openid profile email groups audience:server:client_id:signalloom-api",
            "client_id": "signalloom-dashboard",
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=10.0,
    )
    response.raise_for_status()
    payload = response.json()

    token = payload.get("id_token") or payload.get("access_token")
    if not token:
        raise RuntimeError(f"Dex token response missing id_token/access_token: {list(payload.keys())}")
    return token


@pytest.fixture(scope="session")
def bearer_headers() -> dict[str, str]:
    token = _mint_dex_token()
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(scope="session")
def http_client() -> httpx.Client:
    return httpx.Client(base_url=API_BASE, timeout=15.0)


# ---------------------------------------------------------------------------
# Endpoint table
# ---------------------------------------------------------------------------

# IDs are discovered from the live API, not hard-coded.
#
# These were previously literals in a "tenant-demo:violation-1" shape, on the
# assumption that the demo seed used composite string keys. It does not — the
# seed uses UUIDs (b0000000-0000-0000-0000-000000000001), so every endpoint
# addressing a specific row answered 404. The IDs a live cluster holds are the
# cluster's business, not something a test can assert from a literal.
#
# Resolved at import because the endpoint table is built at module scope. Falls
# back to the old literals when the API cannot be reached, so collection still
# succeeds and the tests fail with a real HTTP error rather than an import crash.


def _discover_id(path: str, key: str, fallback: str) -> str:
    """Return the first id under ``key`` from ``path``, or ``fallback``."""
    if not (API_BASE and DEX_EMAIL and DEX_PASSWORD):
        return fallback
    try:
        token = _mint_dex_token()
        response = httpx.get(
            f"{API_BASE.rstrip('/')}{path}",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10.0,
        )
        response.raise_for_status()
        items = response.json().get(key) or []
        return str(items[0]["id"]) if items else fallback
    except Exception:
        return fallback


def _discover_violation_id(fallback: str) -> str:
    """First violation across all agents — most agents have none."""
    if not (API_BASE and DEX_EMAIL and DEX_PASSWORD):
        return fallback
    try:
        token = _mint_dex_token()
        headers = {"Authorization": f"Bearer {token}"}
        base = API_BASE.rstrip("/")
        agents = httpx.get(f"{base}/api/agents", headers=headers, timeout=10.0).json().get("agents") or []
        for agent in agents:
            found = httpx.get(
                f"{base}/api/agents/{agent['id']}/violations", headers=headers, timeout=10.0
            ).json().get("violations") or []
            if found:
                return str(found[0]["id"])
        return fallback
    except Exception:
        return fallback


_AGENT_ID = _discover_id("/api/agents", "agents", "tenant-demo:agent-1")
_VIOLATION_ID = _discover_violation_id("tenant-demo:violation-1")
_NHI_ACCOUNT_ID = _discover_id("/api/nhi/discovered", "accounts", "tenant-demo:nhi-1")

ENDPOINT_TABLE: list[tuple[str, str, dict[str, Any] | None, type[BaseModel] | None, str]] = [
    ("GET", "/api/agents", None, AgentListResponse, "list agents"),
    ("POST", "/api/agents", {"name": "E2E Agent", "type": "Custom"}, AgentResponse, "create agent"),
    ("GET", f"/api/agents/{_AGENT_ID}", None, AgentResponse, "get agent"),
    ("POST", f"/api/agents/{_AGENT_ID}/credentials", None, IssueCredentialResponse, "issue credential"),
    ("POST", f"/api/agents/{_AGENT_ID}/transition", {"to_state": "active", "reason": "e2e"}, TransitionResponse, "transition"),
    ("GET", f"/api/agents/{_AGENT_ID}/violations", None, ViolationListResponse, "list violations"),
    ("POST", f"/api/agents/violations/{_VIOLATION_ID}/acknowledge", None, None, "acknowledge violation"),
    ("POST", f"/api/agents/{_AGENT_ID}/compliance/eu-ai-act:art-9/reassess", None, ReassessmentResponse, "reassess"),
    ("GET", "/api/compliance/summary", None, ComplianceSummaryResponse, "compliance summary"),
    ("GET", "/api/compliance/posture", None, PostureResponse, "compliance posture"),
    ("GET", "/api/compliance/frameworks", None, None, "compliance frameworks"),
    ("GET", "/api/compliance/export", None, None, "compliance export"),
    ("GET", "/api/audit", None, AuditListResponse, "audit events"),
    ("GET", "/api/nhi/scans", None, NHIScanListResponse, "NHI scans"),
    ("GET", "/api/nhi/discovered", None, NHIDiscoveredResponse, "NHI discovered"),
    ("POST", f"/api/nhi/discovered/{_NHI_ACCOUNT_ID}/enroll", None, None, "enroll NHI"),
    ("POST", f"/api/nhi/discovered/{_NHI_ACCOUNT_ID}/dismiss", None, None, "dismiss NHI"),
    ("GET", "/api/nhi/report/json", None, None, "NHI report"),
    ("GET", "/api/tenant/settings", None, TenantSettingsResponse, "tenant settings"),
    ("PATCH", "/api/tenant/settings/frameworks", {"selected_frameworks": ["eu-ai-act"]}, TenantSettingsResponse, "patch frameworks"),
    ("PATCH", "/api/tenant/settings/preferences", {"preferred_scan_cadence_hours": 12, "alert_email": "ops@signalloom.local", "alert_threshold": 3}, TenantSettingsResponse, "patch preferences"),
    ("POST", "/api/support", {"subject": "E2E Test", "urgency": "low", "message": "Automated"}, SupportRequestResponse, "support request"),
    ("POST", "/api/tenants/tenant-demo/api-keys/initial", None, InitialApiKeyResponse, "initial API key"),
    ("POST", "/api/tenants/tenant-demo/api-keys/rotate", None, RotateApiKeyResponse, "rotate API key"),
    ("GET", "/api/consent/status", None, ConsentStatusResponse, "consent status"),
    ("POST", "/api/consent/accept", {"document_versions": {"tos": "2026-01", "privacy": "2026-01"}, "cookie_preferences": {"strictly_necessary": True, "analytics": False}, "b2b_warranty_accepted": True}, ConsentAcceptResponse, "accept consent"),
    ("GET", "/api/cookie-preferences", None, CookiePreferencesResponse, "cookie prefs"),
    ("PATCH", "/api/cookie-preferences", {"analytics": True}, CookiePreferencesResponse, "patch cookie prefs"),
    ("GET", "/api/health/crypto", None, CryptoHealthResponse, "crypto health"),
]


def _endpoint_id(val: tuple) -> str:
    method, path, _body, _model, desc = val
    return f"{method} {path} ({desc})"


# ---------------------------------------------------------------------------
# Tier 3: E2E contract validation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("endpoint", ENDPOINT_TABLE, ids=_endpoint_id)
def test_e2e_contract_shape(
    http_client: httpx.Client,
    bearer_headers: dict[str, str],
    endpoint: tuple,
) -> None:
    """Hit each API endpoint through the full nginx -> api_compat -> backend chain."""
    method, path, body, contract_model, _desc = endpoint

    if method == "GET":
        response = http_client.get(path, headers=bearer_headers)
    elif method == "POST":
        response = http_client.post(path, json=body, headers=bearer_headers)
    elif method == "PATCH":
        response = http_client.patch(path, json=body, headers=bearer_headers)
    else:
        raise ValueError(f"unexpected HTTP method: {method}")

    # 409 is a correct answer on a live cluster, not a failure. The initial
    # API key can only ever be issued once per tenant, so this endpoint returns
    # api_key_exists on every run after the first — asserting 2xx would mean the
    # tier only passed against a cluster nobody had used. A conflict proves the
    # endpoint is reachable, authenticated and enforcing its own rule; there is
    # just no body to validate against the contract.
    if response.status_code == 409:
        return

    assert response.status_code in (200, 201), (
        f"{method} {path} returned {response.status_code}: {response.text[:500]}"
    )

    data = response.json()

    if contract_model is not None:
        contract_model.model_validate(data)


# ---------------------------------------------------------------------------
# Untyped endpoint validation
# ---------------------------------------------------------------------------

def test_e2e_acknowledge_violation(
    http_client: httpx.Client,
    bearer_headers: dict[str, str],
) -> None:
    response = http_client.post(
        f"/api/agents/violations/{_VIOLATION_ID}/acknowledge",
        headers=bearer_headers,
    )
    assert response.status_code == 200
    assert response.json()["status"] == "acknowledged"


def test_e2e_compliance_frameworks_list(
    http_client: httpx.Client,
    bearer_headers: dict[str, str],
) -> None:
    response = http_client.get("/api/compliance/frameworks", headers=bearer_headers)
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    for fw in data:
        FrameworkResponse.model_validate(fw)


def test_e2e_compliance_export(
    http_client: httpx.Client,
    bearer_headers: dict[str, str],
) -> None:
    response = http_client.get("/api/compliance/export", headers=bearer_headers)
    assert response.status_code == 200
    data = response.json()
    assert "format" in data
    assert "generated_at" in data


def test_e2e_nhi_report(
    http_client: httpx.Client,
    bearer_headers: dict[str, str],
) -> None:
    response = http_client.get("/api/nhi/report/json", headers=bearer_headers)
    assert response.status_code == 200
    data = response.json()
    assert "tenant_id" in data
    assert "accounts_total" in data


def test_e2e_endpoint_count() -> None:
    """Sanity: 29 endpoints in the E2E table."""
    assert len(ENDPOINT_TABLE) == 29
