"""Tier 1 -- Consumer-driven contract tests (hermetic, no Postgres).

Validates that every endpoint in ``api_compat.py`` returns a response whose
shape matches the consumer contract defined in ``tests/contract.py`` (which
mirrors ``dashboard-signalloom/src/types/api.ts``).

Runs against the in-memory fixture store -- no external services, no database.
The JWKS-patching + token-minting setup is reused from the existing test suite.
"""
from __future__ import annotations

import socket
import time
from contextlib import contextmanager
from types import SimpleNamespace
from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from pydantic import BaseModel

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing

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
    RevokeCredentialResponse,
    RotateApiKeyResponse,
    SupportRequestResponse,
    TenantSettingsResponse,
    TransitionResponse,
    ViolationListResponse,
)

# ---------------------------------------------------------------------------
# Auth helpers (same pattern as test_api_compat.py / test_agent_discovery.py)
# ---------------------------------------------------------------------------

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _ReadyPool:
    async def close(self) -> None:
        pass


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(subject: str = "alice") -> str:
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
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Fake async client for endpoints that call the fake-integration-proxy
# (GET /api/agents, GET /api/health/crypto)
# ---------------------------------------------------------------------------

class _FakeDiscoveryResponse:
    def __init__(self, payload: Any) -> None:
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> Any:
        return self._payload


class _FakeAsyncClient:
    """Intercepts httpx.AsyncClient for both agent discovery and crypto health."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> "_FakeAsyncClient":
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> bool:
        return False

    async def get(self, url: str) -> _FakeDiscoveryResponse:
        if "crypto" in url:
            return _FakeDiscoveryResponse({
                "proofs": [
                    {
                        "name": "rekor-inclusion",
                        "kind": "positive",
                        "status": "passed",
                        "title": "Rekor inclusion proof",
                        "description": "Transparency entry exists",
                        "expectation": "Proof should verify against Rekor",
                        "evidence": "uuid=1234",
                    },
                ],
                "namespace": "fe-signalloom",
            })
        return _FakeDiscoveryResponse({
            "agents": [
                {
                    "id": "pod-inventory-agent",
                    "name": "Inventory Agent",
                    "type": "service",
                    "state": "ready",
                    "model": "gpt-5.4-mini",
                    "created_at": "2026-07-27T10:00:00Z",
                },
            ],
            "namespace": "fe-signalloom-agents",
        })


# ---------------------------------------------------------------------------
# Fixture: hermetic test client
# ---------------------------------------------------------------------------

@contextmanager
def _hermetic_client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-a", "bob": "tenant-b"},
    )
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
    monkeypatch.setattr(api_compat.httpx, "AsyncClient", _FakeAsyncClient)

    # Force api_compat into fixture mode.
    #
    # There are two independent pool globals: db.connection._pool, which
    # set_pool_for_testing() below drives and /readyz reads, and api_compat._pool,
    # which the request handlers use. api_compat._get_pool() lazily builds its own
    # pool from settings.database_url, so with DATABASE_URL exported in the
    # environment — exactly what the `integration` and `e2e` tiers do — the
    # handlers opened a real connection, tripped the no-network guard below, and
    # returned 500. Tier 1 is hermetic by contract; it must guarantee that rather
    # than inherit whatever is in the ambient environment.
    #
    # Resetting both globals matters as much as blanking the DSN: _pool survives
    # between tests in a session, so a pool built before this fixture ran would
    # still be handed out.
    monkeypatch.setattr(settings, "database_url", "")
    monkeypatch.setattr(api_compat, "_pool", None)
    monkeypatch.setattr(api_compat, "_pool_init_attempted", False)

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in contract tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(_ReadyPool())

    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    with _hermetic_client(monkeypatch) as c:
        yield c


# ---------------------------------------------------------------------------
# Endpoint table: every row is (method, path, request_body, contract_model)
#
# For endpoints that return untyped dicts (acknowledge, enroll, dismiss,
# compliance/export, nhi/report/json) we use None as contract_model and
# validate the raw dict shape separately.
# ---------------------------------------------------------------------------

_SEEDED_AGENT_ID = "tenant-a:agent-1"
_SEEDED_VIOLATION_ID = "tenant-a:violation-1"
_SEEDED_NHI_ACCOUNT_ID = "tenant-a:nhi-1"

ENDPOINT_TABLE: list[tuple[str, str, dict[str, Any] | None, type[BaseModel] | None, str]] = [
    # (method, path, body, contract_model, description)
    ("GET", "/api/agents", None, AgentListResponse, "list agents via discovery proxy"),
    ("POST", "/api/agents", {"name": "Test Agent", "type": "Custom"}, AgentResponse, "create agent"),
    ("GET", f"/api/agents/{_SEEDED_AGENT_ID}", None, AgentResponse, "get single agent"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/credentials", None, IssueCredentialResponse, "issue credential"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/credentials/revoke", None, RevokeCredentialResponse, "revoke credentials"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/transition", {"to_state": "active", "reason": "test"}, TransitionResponse, "transition agent"),
    ("GET", f"/api/agents/{_SEEDED_AGENT_ID}/violations", None, ViolationListResponse, "list agent violations"),
    ("POST", f"/api/agents/violations/{_SEEDED_VIOLATION_ID}/acknowledge", None, None, "acknowledge violation"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/compliance/eu-ai-act:art-9/reassess", None, ReassessmentResponse, "request reassessment"),
    ("GET", "/api/compliance/summary", None, ComplianceSummaryResponse, "compliance summary"),
    ("GET", "/api/compliance/posture", None, PostureResponse, "compliance posture"),
    ("GET", "/api/compliance/frameworks", None, None, "compliance frameworks (list)"),
    ("GET", "/api/compliance/export", None, None, "compliance export"),
    ("GET", "/api/audit", None, AuditListResponse, "audit events"),
    ("GET", "/api/nhi/scans", None, NHIScanListResponse, "NHI scans"),
    ("GET", "/api/nhi/discovered", None, NHIDiscoveredResponse, "NHI discovered accounts"),
    ("POST", f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/enroll", None, None, "enroll NHI account"),
    ("POST", f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/dismiss", None, None, "dismiss NHI account"),
    ("GET", "/api/nhi/report/json", None, None, "NHI report JSON"),
    ("GET", "/api/tenant/settings", None, TenantSettingsResponse, "tenant settings"),
    ("PATCH", "/api/tenant/settings/frameworks", {"selected_frameworks": ["eu-ai-act", "nist-ai-rmf"]}, TenantSettingsResponse, "patch tenant frameworks"),
    ("PATCH", "/api/tenant/settings/preferences", {"preferred_scan_cadence_hours": 12, "alert_email": "ops@signalloom.local", "alert_threshold": 3}, TenantSettingsResponse, "patch tenant preferences"),
    ("POST", "/api/support", {"subject": "Test", "urgency": "normal", "message": "Help"}, SupportRequestResponse, "create support request"),
    ("POST", "/api/tenants/tenant-a/api-keys/initial", None, InitialApiKeyResponse, "create initial API key"),
    ("POST", "/api/tenants/tenant-a/api-keys/rotate", None, RotateApiKeyResponse, "rotate API key"),
    ("GET", "/api/consent/status", None, ConsentStatusResponse, "consent status"),
    ("POST", "/api/consent/accept", {"document_versions": {"tos": "2026-01", "privacy": "2026-01"}, "cookie_preferences": {"strictly_necessary": True, "analytics": True}, "b2b_warranty_accepted": True}, ConsentAcceptResponse, "accept consent"),
    ("GET", "/api/cookie-preferences", None, CookiePreferencesResponse, "get cookie preferences"),
    ("PATCH", "/api/cookie-preferences", {"analytics": True}, CookiePreferencesResponse, "patch cookie preferences"),
    ("GET", "/api/health/crypto", None, CryptoHealthResponse, "crypto health"),
]


def _endpoint_id(val: tuple) -> str:
    method, path, _body, _model, desc = val
    return f"{method} {path} ({desc})"


# ---------------------------------------------------------------------------
# Tier 1: Contract shape validation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("endpoint", ENDPOINT_TABLE, ids=_endpoint_id)
def test_contract_shape_matches_consumer(client: TestClient, endpoint: tuple) -> None:
    """For each API endpoint: call it, assert 2xx, validate against the consumer contract model."""
    method, path, body, contract_model, _desc = endpoint
    headers = _bearer(_token_for("alice"))

    if method == "GET":
        response = client.get(path, headers=headers)
    elif method == "POST":
        response = client.post(path, json=body, headers=headers)
    elif method == "PATCH":
        response = client.patch(path, json=body, headers=headers)
    else:
        raise ValueError(f"unexpected HTTP method: {method}")

    assert response.status_code in (200, 201), (
        f"{method} {path} returned {response.status_code}: {response.text}"
    )

    data = response.json()

    if contract_model is not None:
        contract_model.model_validate(data)


# ---------------------------------------------------------------------------
# Validation for endpoints that return untyped dicts
# ---------------------------------------------------------------------------

def test_acknowledge_violation_response_shape(client: TestClient) -> None:
    """POST /api/agents/violations/{id}/acknowledge returns {status: 'acknowledged'}."""
    # Seed tenant data first via a GET
    client.get("/api/tenant/settings", headers=_bearer(_token_for("alice")))

    response = client.post(
        f"/api/agents/violations/{_SEEDED_VIOLATION_ID}/acknowledge",
        headers=_bearer(_token_for("alice")),
    )
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, dict)
    assert data["status"] == "acknowledged"


def test_enroll_nhi_account_response_shape(client: TestClient) -> None:
    """POST /api/nhi/discovered/{id}/enroll returns {account_id, status}."""
    client.get("/api/tenant/settings", headers=_bearer(_token_for("alice")))

    response = client.post(
        f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/enroll",
        headers=_bearer(_token_for("alice")),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["account_id"] == _SEEDED_NHI_ACCOUNT_ID
    assert data["status"] == "enrollment_requested"


def test_dismiss_nhi_account_response_shape(client: TestClient) -> None:
    """POST /api/nhi/discovered/{id}/dismiss returns {account_id, status}."""
    client.get("/api/tenant/settings", headers=_bearer(_token_for("alice")))

    response = client.post(
        f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/dismiss",
        headers=_bearer(_token_for("alice")),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["account_id"] == _SEEDED_NHI_ACCOUNT_ID
    assert data["status"] == "dismissed"


def test_nhi_detail_rejects_fixture_accounts_without_database(client: TestClient) -> None:
    """A fixture list entry never becomes a synthetic detail response."""
    alice_headers = _bearer(_token_for("alice"))
    listed = client.get("/api/nhi/discovered", headers=alice_headers)
    assert listed.status_code == 200
    account_id = listed.json()["accounts"][0]["id"]

    detail = client.get(f"/api/nhi/discovered/{account_id}", headers=alice_headers)
    assert detail.status_code == 404
    assert detail.json()["error"]["code"] == "not_found"


def test_nhi_detail_returns_not_found_without_creating_account(client: TestClient) -> None:
    """An absent detail identifier remains absent after a failed lookup."""
    headers = _bearer(_token_for("alice"))
    missing_id = "tenant-a:missing-nhi-account"

    response = client.get(f"/api/nhi/discovered/{missing_id}", headers=headers)
    assert response.status_code == 404

    listed = client.get("/api/nhi/discovered", headers=headers)
    assert missing_id not in {account["id"] for account in listed.json()["accounts"]}


def test_compliance_export_response_shape(client: TestClient) -> None:
    """GET /api/compliance/export returns {format, generated_at, url}."""
    response = client.get("/api/compliance/export", headers=_bearer(_token_for("alice")))
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data["format"], str)
    assert isinstance(data["generated_at"], str)
    assert isinstance(data["url"], str)


def test_compliance_frameworks_validates_as_list_of_framework_response(client: TestClient) -> None:
    """GET /api/compliance/frameworks returns a list of FrameworkResponse."""
    response = client.get("/api/compliance/frameworks", headers=_bearer(_token_for("alice")))
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    for framework in data:
        FrameworkResponse.model_validate(framework)


def test_nhi_report_json_response_shape(client: TestClient) -> None:
    """GET /api/nhi/report/json returns {tenant_id, generated_at, accounts_total, at_risk}."""
    client.get("/api/tenant/settings", headers=_bearer(_token_for("alice")))

    response = client.get("/api/nhi/report/json", headers=_bearer(_token_for("alice")))
    assert response.status_code == 200
    data = response.json()
    assert data["tenant_id"] == "tenant-a"
    assert isinstance(data["generated_at"], str)
    assert isinstance(data["accounts_total"], int)
    assert isinstance(data["at_risk"], int)


# ---------------------------------------------------------------------------
# Coverage assertion: ensure the fixture-compatible table stays exact
# ---------------------------------------------------------------------------

def test_endpoint_table_covers_all_30_fixture_compatible_routes() -> None:
    """Sanity check: the fixture-compatible table has exactly 30 entries."""
    assert len(ENDPOINT_TABLE) == 30, (
        f"expected 30 endpoints in the table, got {len(ENDPOINT_TABLE)}"
    )
