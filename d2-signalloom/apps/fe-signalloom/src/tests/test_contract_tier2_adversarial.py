"""Adversarial and offline contract tests for Tier 2 routes.

Provides adversarial verification for all Tier 2 routes when DATABASE_URL is
not set or when the database is unavailable:
1. Authentication gates: unauthenticated requests return 401, forged or
   restricted tokens return 401/403 with structured error envelopes.
2. Input validation: invalid or malformed bodies return 422 with structured
   error envelopes rather than reaching backend execution.
3. Database failure safety: when the database is unreachable, mutating
   endpoints fail closed with HTTP 503 database_unavailable and never leak
   raw unhandled tracebacks.
4. Offline contract shapes: read endpoints in offline/fixture mode preserve
   consumer contract schemas matching tests/contract.py.
"""
from __future__ import annotations

import asyncio
import socket
import time
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch

import asyncpg
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from pydantic import BaseModel

import api_compat
from api_compat import ErrorResponse, settings
from db.connection import set_pool_for_testing
from main import app
from tests.contract import (
    AgentListResponse,
    AgentResponse,
    AuditListResponse,
    ComplianceSummaryResponse,
    ConsentAcceptResponse,
    ConsentStatusResponse,
    CookiePreferencesResponse,
    CryptoHealthResponse,
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

SEEDED_TENANT = "tenant-demo"
_SEEDED_AGENT_ID = "a0000000-0000-0000-0000-000000000001"
_SEEDED_VIOLATION_ID = "b0000000-0000-0000-0000-000000000001"
_SEEDED_NHI_ACCOUNT_ID = "e0000000-0000-0000-0000-000000000001"

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(
    subject: str = "alice",
    signing_key: Any = TEST_SIGNING_KEY,
    kid: str = "test-key",
    scope: str | None = None,
    identity_type: str | None = None,
) -> str:
    now = int(time.time())
    payload: dict[str, Any] = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
    }
    if scope:
        payload["scope"] = scope
    if identity_type:
        payload["identity_type"] = identity_type
    return jwt.encode(
        payload,
        signing_key,
        algorithm="RS256",
        headers={"kid": kid, "typ": "JWT"},
    )


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


class _FakeDiscoveryResponse:
    def __init__(self, payload: Any) -> None:
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> Any:
        return self._payload


class _FakeAsyncClient:
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> _FakeAsyncClient:
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
        })


class _ReadyPool:
    async def close(self) -> None:
        pass


@pytest.fixture(autouse=True)
def _clean_pool():
    set_pool_for_testing(_ReadyPool())
    yield
    set_pool_for_testing(None)


@pytest.fixture
def offline_client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": SEEDED_TENANT, "bob": "tenant-b"},
    )
    monkeypatch.setattr(settings, "database_url", "")
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
    monkeypatch.setattr(api_compat.httpx, "AsyncClient", _FakeAsyncClient)
    monkeypatch.setattr(api_compat, "_pool", None)
    monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.UNKNOWN)
    monkeypatch.setattr(api_compat, "_pool_retry_after", 0.0)

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in offline tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


ALL_TIER2_ENDPOINTS: list[tuple[str, str, dict[str, Any] | None, type[BaseModel] | None, str]] = [
    ("GET", "/api/agents", None, AgentListResponse, "list agents"),
    ("POST", "/api/agents", {"name": "Integration Agent", "type": "COTS"}, AgentResponse, "create agent"),
    ("GET", f"/api/agents/{_SEEDED_AGENT_ID}", None, AgentResponse, "get agent"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/credentials", None, IssueCredentialResponse, "issue credential"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/transition", {"to_state": "active", "reason": "integration test"}, TransitionResponse, "transition agent"),
    ("GET", f"/api/agents/{_SEEDED_AGENT_ID}/violations", None, ViolationListResponse, "list violations"),
    ("POST", f"/api/agents/violations/{_SEEDED_VIOLATION_ID}/acknowledge", None, None, "acknowledge violation"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/compliance/eu-ai-act:art-9/reassess", None, ReassessmentResponse, "reassess"),
    ("GET", "/api/compliance/summary", None, ComplianceSummaryResponse, "compliance summary"),
    ("GET", "/api/compliance/posture", None, PostureResponse, "compliance posture"),
    ("GET", "/api/compliance/frameworks", None, None, "compliance frameworks"),
    ("GET", "/api/compliance/export", None, None, "compliance export"),
    ("GET", "/api/audit", None, AuditListResponse, "audit events"),
    ("GET", "/api/nhi/scans", None, NHIScanListResponse, "NHI scans"),
    ("GET", "/api/nhi/discovered", None, NHIDiscoveredResponse, "NHI discovered"),
    ("POST", f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/enroll", None, None, "enroll NHI"),
    ("POST", f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/dismiss", None, None, "dismiss NHI"),
    ("GET", "/api/nhi/report/json", None, None, "NHI report"),
    ("GET", "/api/tenant/settings", None, TenantSettingsResponse, "tenant settings"),
    ("PATCH", "/api/tenant/settings/frameworks", {"selected_frameworks": ["eu-ai-act"]}, TenantSettingsResponse, "patch frameworks"),
    ("PATCH", "/api/tenant/settings/preferences", {"preferred_scan_cadence_hours": 12, "alert_email": "ops@signalloom.local", "alert_threshold": 3}, TenantSettingsResponse, "patch preferences"),
    ("POST", "/api/support", {"subject": "Tier2 Test", "urgency": "high", "message": "Integration"}, SupportRequestResponse, "support request"),
    ("POST", f"/api/tenants/{SEEDED_TENANT}/api-keys/rotate", None, RotateApiKeyResponse, "rotate API key"),
    ("GET", "/api/consent/status", None, ConsentStatusResponse, "consent status"),
    ("POST", "/api/consent/accept", {"document_versions": {"tos": "2026-01", "privacy": "2026-01"}, "cookie_preferences": {"strictly_necessary": True, "analytics": False}, "b2b_warranty_accepted": True}, ConsentAcceptResponse, "accept consent"),
    ("GET", "/api/cookie-preferences", None, CookiePreferencesResponse, "cookie preferences"),
    ("PATCH", "/api/cookie-preferences", {"analytics": True}, CookiePreferencesResponse, "patch cookie prefs"),
    ("GET", "/api/health/crypto", None, CryptoHealthResponse, "crypto health"),
]

MUTATING_TIER2_ENDPOINTS: list[tuple[str, str, dict[str, Any] | None, str]] = [
    ("POST", "/api/agents", {"name": "Test Agent", "type": "COTS"}, "create agent"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/credentials", None, "issue credential"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/credentials/revoke", None, "revoke credential"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/transition", {"to_state": "active", "reason": "integration test"}, "transition agent"),
    ("POST", f"/api/agents/violations/{_SEEDED_VIOLATION_ID}/acknowledge", None, "acknowledge violation"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/compliance/eu-ai-act:art-9/reassess", None, "reassess compliance"),
    ("POST", f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/enroll", None, "enroll NHI account"),
    ("POST", f"/api/nhi/discovered/{_SEEDED_NHI_ACCOUNT_ID}/dismiss", None, "dismiss NHI account"),
    ("PATCH", "/api/tenant/settings/frameworks", {"selected_frameworks": ["eu-ai-act"]}, "patch frameworks"),
    ("PATCH", "/api/tenant/settings/preferences", {"preferred_scan_cadence_hours": 12, "alert_email": "ops@signalloom.local", "alert_threshold": 3}, "patch preferences"),
    ("POST", "/api/support", {"subject": "Tier2 Test", "urgency": "high", "message": "Integration"}, "support request"),
    ("POST", f"/api/tenants/{SEEDED_TENANT}/api-keys/rotate", None, "rotate API key"),
    ("POST", f"/api/tenants/{SEEDED_TENANT}/api-keys/initial", None, "initial API key"),
    ("POST", "/api/consent/accept", {"document_versions": {"tos": "2026-01", "privacy": "2026-01"}, "cookie_preferences": {"strictly_necessary": True, "analytics": False}, "b2b_warranty_accepted": True}, "accept consent"),
    ("PATCH", "/api/cookie-preferences", {"analytics": True}, "patch cookie prefs"),
]

INVALID_BODY_CASES: list[tuple[str, str, dict[str, Any], str]] = [
    ("POST", "/api/agents", {"name": "Missing Type"}, "missing required type field"),
    ("POST", "/api/agents", {"name": "Valid", "type": "Custom", "disallowed": 123}, "forbidden extra field"),
    ("POST", f"/api/agents/{_SEEDED_AGENT_ID}/transition", {"to_state": "invalid_enum_state"}, "invalid transition state"),
    ("PATCH", "/api/tenant/settings/frameworks", {"selected_frameworks": "not-a-list"}, "selected_frameworks is string"),
    ("PATCH", "/api/tenant/settings/preferences", {"preferred_scan_cadence_hours": "not-int"}, "invalid cadence type"),
    ("POST", "/api/support", {"subject": "Test", "urgency": "extreme_invalid", "message": "msg"}, "invalid urgency enum"),
    ("POST", "/api/consent/accept", {"document_versions": "not-a-dict"}, "invalid document_versions type"),
    ("PATCH", "/api/cookie-preferences", {"analytics": "not-a-bool"}, "invalid boolean type"),
]


def _endpoint_desc(val: tuple) -> str:
    return f"{val[0]} {val[1]} ({val[4]})"


def _mutation_desc(val: tuple) -> str:
    return f"{val[0]} {val[1]} ({val[3]})"


def _invalid_case_desc(val: tuple) -> str:
    return f"{val[0]} {val[1]} ({val[3]})"


# ===========================================================================
# 1. Authentication Gates
# ===========================================================================


class TestTier2AuthGates:
    """Authentication gates must protect all Tier 2 routes without leaking server state."""

    @pytest.mark.parametrize("endpoint", ALL_TIER2_ENDPOINTS, ids=_endpoint_desc)
    def test_unauthenticated_request_returns_401(
        self, offline_client: TestClient, endpoint: tuple
    ) -> None:
        """Every Tier 2 endpoint without Authorization header must return 401."""
        method, path, body, _model, _desc = endpoint
        if method == "GET":
            resp = offline_client.get(path)
        elif method == "POST":
            resp = offline_client.post(path, json=body)
        elif method == "PATCH":
            resp = offline_client.patch(path, json=body)
        else:
            raise ValueError(f"unexpected method: {method}")

        assert resp.status_code == 401, f"{method} {path} returned {resp.status_code}: {resp.text}"
        data = resp.json()
        assert "error" in data, f"missing error key in {data}"
        assert data["error"]["code"] == "authentication_required"
        ErrorResponse.model_validate(data)

    @pytest.mark.parametrize(
        "bad_auth",
        [
            "Bearer ",
            "Bearer invalid-jwt-string",
            "Basic dXNlcjpwYXNz",
            "Token xyz123",
        ],
    )
    def test_invalid_bearer_token_returns_401(
        self, offline_client: TestClient, bad_auth: str
    ) -> None:
        """Malformed or unsupported authorization headers must return 401."""
        resp = offline_client.get("/api/agents", headers={"Authorization": bad_auth})
        assert resp.status_code == 401
        data = resp.json()
        assert data["error"]["code"] == "invalid_token"
        ErrorResponse.model_validate(data)

    def test_unknown_signing_key_returns_401(self, offline_client: TestClient) -> None:
        """A JWT signed with an unrecognized key must be rejected with 401."""
        forged_token = _token_for("alice", signing_key=OTHER_SIGNING_KEY, kid="unknown-key")
        resp = offline_client.get("/api/agents", headers=_bearer(forged_token))
        assert resp.status_code == 401
        data = resp.json()
        assert data["error"]["code"] == "invalid_token"
        ErrorResponse.model_validate(data)

    def test_unmapped_tenant_subject_returns_403(self, offline_client: TestClient) -> None:
        """A valid JWT with a subject not bound to any tenant must be refused with 403."""
        unmapped_token = _token_for("mallory")
        resp = offline_client.get("/api/agents", headers=_bearer(unmapped_token))
        assert resp.status_code == 403
        data = resp.json()
        assert data["error"]["code"] == "tenant_forbidden"
        ErrorResponse.model_validate(data)

    def test_restricted_scope_token_returns_403(self, offline_client: TestClient) -> None:
        """Tokens with restricted external-host scope must not access operator APIs."""
        restricted_token = _token_for("alice", scope="audit-upload-only")
        resp = offline_client.get("/api/agents", headers=_bearer(restricted_token))
        assert resp.status_code == 403
        data = resp.json()
        assert data["error"]["code"] == "host_credential_scope_restricted"
        ErrorResponse.model_validate(data)


# ===========================================================================
# 2. Input Validation Gates
# ===========================================================================


class TestTier2InputValidation:
    """Input validation must reject malformed requests with 422 before backend processing."""

    @pytest.mark.parametrize("case", INVALID_BODY_CASES, ids=_invalid_case_desc)
    def test_invalid_body_returns_422(
        self, offline_client: TestClient, case: tuple
    ) -> None:
        """Invalid payloads must be rejected with 422 invalid_request."""
        method, path, body, _desc = case
        headers = _bearer(_token_for("alice"))
        if method == "POST":
            resp = offline_client.post(path, json=body, headers=headers)
        elif method == "PATCH":
            resp = offline_client.patch(path, json=body, headers=headers)
        else:
            raise ValueError(f"unexpected method: {method}")

        assert resp.status_code == 422, f"{method} {path} returned {resp.status_code}: {resp.text}"
        data = resp.json()
        assert data["error"]["code"] == "invalid_request"
        ErrorResponse.model_validate(data)

    def test_malformed_json_payload_returns_422(self, offline_client: TestClient) -> None:
        """Non-JSON body with application/json header must return 422 invalid_request."""
        headers = _bearer(_token_for("alice"))
        headers["Content-Type"] = "application/json"
        resp = offline_client.post("/api/agents", content="not-a-valid-json-string", headers=headers)
        assert resp.status_code == 422
        data = resp.json()
        assert data["error"]["code"] == "invalid_request"
        ErrorResponse.model_validate(data)

    def test_non_uuid_path_parameter_handled_safely(self, offline_client: TestClient) -> None:
        """Non-UUID path parameter must fail gracefully without unhandled tracebacks."""
        headers = _bearer(_token_for("alice"))
        resp = offline_client.post("/api/agents/not-a-uuid/credentials", headers=headers)
        assert resp.status_code in (404, 422), f"unexpected status: {resp.status_code}"
        assert "Traceback" not in resp.text
        assert resp.headers.get("content-type", "").startswith("application/json")


# ===========================================================================
# 3. Database Unavailable Fail-Safe
# ===========================================================================


class TestTier2DatabaseUnavailable:
    """When the database is unreachable or down, endpoints must fail safely with 503."""

    @pytest.mark.parametrize("endpoint", MUTATING_TIER2_ENDPOINTS, ids=_mutation_desc)
    def test_mutations_fail_closed_503_when_database_unreachable(
        self, offline_client: TestClient, monkeypatch: pytest.MonkeyPatch, endpoint: tuple
    ) -> None:
        """Mutations must fail closed with 503 database_unavailable when database is down."""
        method, path, body, _desc = endpoint
        monkeypatch.setattr(settings, "database_url", "postgresql://unused:unused@127.0.0.1:1/unused")
        monkeypatch.setattr(api_compat, "_pool", None)
        monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.UNKNOWN)
        monkeypatch.setattr(api_compat, "_pool_retry_after", 0.0)

        async def _always_fails_connect(*_args: Any, **_kwargs: Any) -> None:
            raise OSError("connection refused")

        monkeypatch.setattr(asyncpg, "create_pool", _always_fails_connect)

        headers = _bearer(_token_for("alice"))
        if method == "POST":
            resp = offline_client.post(path, json=body, headers=headers)
        elif method == "PATCH":
            resp = offline_client.patch(path, json=body, headers=headers)
        else:
            raise ValueError(f"unexpected method: {method}")

        assert resp.status_code == 503, (
            f"{method} {path} returned {resp.status_code} instead of 503: {resp.text[:300]}"
        )
        assert "Traceback" not in resp.text
        assert "<html" not in resp.text.lower()
        data = resp.json()
        assert data["error"]["code"] == "database_unavailable"
        assert "unreachable" in data["error"]["message"].lower() or "requires the audit database" in data["error"]["message"].lower()
        ErrorResponse.model_validate(data)

    def test_mid_query_connection_loss_returns_503(
        self, offline_client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A database connection reset mid-query must return 503 database_unavailable."""
        monkeypatch.setattr(settings, "database_url", "postgresql://unused:unused@127.0.0.1:1/unused")

        class _BrokenConnectionPool:
            async def fetch(self, *args: Any, **kwargs: Any) -> list[Any]:
                raise asyncpg.PostgresConnectionError("connection reset by peer")

            async def fetchrow(self, *args: Any, **kwargs: Any) -> Any:
                raise asyncpg.PostgresConnectionError("connection reset by peer")

            async def execute(self, *args: Any, **kwargs: Any) -> str:
                raise asyncpg.PostgresConnectionError("connection reset by peer")

            async def close(self) -> None:
                pass

        monkeypatch.setattr(api_compat, "_pool", _BrokenConnectionPool())
        monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.READY)

        headers = _bearer(_token_for("alice"))
        resp = offline_client.get("/api/compliance/summary", headers=headers)
        assert resp.status_code == 503
        assert "Traceback" not in resp.text
        data = resp.json()
        assert data["error"]["code"] == "database_unavailable"
        ErrorResponse.model_validate(data)

    def test_mid_query_timeout_returns_503(
        self, offline_client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A query timeout on overloaded pool must return 503 database_unavailable."""
        monkeypatch.setattr(settings, "database_url", "postgresql://unused:unused@127.0.0.1:1/unused")

        class _TimingOutPool:
            async def fetch(self, *args: Any, **kwargs: Any) -> list[Any]:
                raise asyncio.TimeoutError("query timed out waiting for connection")

            async def fetchrow(self, *args: Any, **kwargs: Any) -> Any:
                raise asyncio.TimeoutError("query timed out waiting for connection")

            async def execute(self, *args: Any, **kwargs: Any) -> str:
                raise asyncio.TimeoutError("query timed out waiting for connection")

            async def close(self) -> None:
                pass

        monkeypatch.setattr(api_compat, "_pool", _TimingOutPool())
        monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.READY)

        headers = _bearer(_token_for("alice"))
        resp = offline_client.get("/api/audit", headers=headers)
        assert resp.status_code == 503
        assert "Traceback" not in resp.text
        data = resp.json()
        assert data["error"]["code"] == "database_unavailable"
        ErrorResponse.model_validate(data)


# ===========================================================================
# 4. Offline Fallback Contract Validation
# ===========================================================================


class TestTier2OfflineFallbackContracts:
    """In offline mode (no live database), read endpoints must preserve contract schemas."""

    @pytest.mark.parametrize(
        ("path", "model_cls"),
        [
            ("/api/agents", AgentListResponse),
            ("/api/compliance/summary", ComplianceSummaryResponse),
            ("/api/compliance/posture", PostureResponse),
            ("/api/audit", AuditListResponse),
            ("/api/nhi/scans", NHIScanListResponse),
            ("/api/nhi/discovered", NHIDiscoveredResponse),
            ("/api/tenant/settings", TenantSettingsResponse),
            ("/api/consent/status", ConsentStatusResponse),
            ("/api/cookie-preferences", CookiePreferencesResponse),
            ("/api/health/crypto", CryptoHealthResponse),
        ],
    )
    def test_offline_read_endpoint_contract_shape(
        self, offline_client: TestClient, path: str, model_cls: type[BaseModel]
    ) -> None:
        """Offline read responses must validate against their consumer contract models."""
        headers = _bearer(_token_for("alice"))
        resp = offline_client.get(path, headers=headers)
        assert resp.status_code == 200, f"GET {path} returned {resp.status_code}: {resp.text}"
        data = resp.json()
        model_cls.model_validate(data)
