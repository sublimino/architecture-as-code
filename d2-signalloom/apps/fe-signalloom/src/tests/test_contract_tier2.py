"""Tier 2 -- Integration tests with live Postgres.

Same consumer-contract validation as Tier 1 but against a real database.
Requires ``DATABASE_URL`` in the environment; all tests are skipped otherwise.

Assumes:
  - 004_agent_governance_schema.sql has been applied.
  - data-mock.sql has been applied (provides fixture data).
  - data-reset.sql is available for cleanup after mutation tests.

Migration and seed SQL are expected at:
  - db/migrations/004_agent_governance_schema.sql
  - db/migrations/data-mock.sql
  - db/migrations/data-reset.sql
"""
from __future__ import annotations

import os
import socket
from urllib.parse import urlparse
import subprocess
import time
from pathlib import Path
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
# Skip entire module if DATABASE_URL is not set
# ---------------------------------------------------------------------------

DATABASE_URL = os.environ.get("DATABASE_URL")

pytestmark = pytest.mark.skipif(
    DATABASE_URL is None,
    reason="DATABASE_URL not set -- Tier 2 integration tests require a live Postgres",
)

# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


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
# Fake async client for proxy-backed endpoints
# ---------------------------------------------------------------------------

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
        })


# ---------------------------------------------------------------------------
# Database setup / teardown
# ---------------------------------------------------------------------------

_DB_DIR = Path(__file__).resolve().parent.parent / "db"
_MIGRATIONS_DIR = _DB_DIR / "migrations"


def _run_sql(sql_file: Path) -> None:
    """Execute a SQL file against the database using psql."""
    if not sql_file.exists():
        pytest.skip(f"SQL file not found: {sql_file}")
    subprocess.run(
        ["psql", DATABASE_URL, "-f", str(sql_file)],
        check=True,
        capture_output=True,
        timeout=30,
    )


@pytest.fixture(scope="session", autouse=True)
def _apply_migrations() -> None:
    """Apply schema + seed data before the test session.

    The seed and reset scripts live in ``db/``, not ``db/migrations/`` — the
    module docstring's claim that they sit alongside the migrations was wrong.
    Because the previous code guarded each file with ``if …exists()``, the
    mismatch meant seeding was skipped in silence and every test that expected
    fixture rows failed on its own assertion instead of reporting the real cause.
    A missing file is now an error.
    """
    required = (
        _MIGRATIONS_DIR / "004_agent_governance_schema.sql",
        # 009 widens agent_registry's lifecycle_state CHECK to the vocabulary the
        # API writes. Without it, POST /api/agents and every transition to a
        # state outside 004's four values raise CheckViolationError.
        _MIGRATIONS_DIR / "009_agent_lifecycle_states.sql",
        _DB_DIR / "data-mock.sql",
    )
    for sql_file in required:
        assert sql_file.exists(), f"required SQL file is missing: {sql_file}"
        _run_sql(sql_file)


@pytest.fixture(autouse=True)
def _reset_after_mutation() -> None:
    """Restore the seed after each test to keep tests independent.

    ``data-reset.sql`` TRUNCATEs every governance table -- the seed rows
    included, which its own header acknowledges by instructing callers to run
    ``data-mock.sql`` afterwards. Running only the reset therefore emptied the
    database after the *first* test and left every later test looking at nothing:
    read endpoints still returned a valid empty shape and passed, while anything
    addressing a seeded row got a 404 that looked like an API defect.

    Reset and re-seed are one operation. Splitting them is what made the tier
    order-dependent.
    """
    yield
    for sql_file in (_DB_DIR / "data-reset.sql", _DB_DIR / "data-mock.sql"):
        assert sql_file.exists(), f"required SQL file is missing: {sql_file}"
        _run_sql(sql_file)


# ---------------------------------------------------------------------------
# Test client fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    # alice maps to the tenant the seed actually populates.
    #
    # Tier 1 can invent tenant names because its fixture store seeds whatever
    # tenant it is asked about. Tier 2 reads a real database, and every row in
    # data-mock.sql is tenant-demo; mapping alice to "tenant-a" meant every
    # tenant-scoped query filtered the seed out and the tier silently tested
    # empty result sets.
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": SEEDED_TENANT, "bob": "tenant-b"},
    )
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
    monkeypatch.setattr(api_compat.httpx, "AsyncClient", _FakeAsyncClient)

    # Force a fresh pool per test.
    #
    # api_compat._pool is a module-level global built lazily on first request and
    # never closed. TestClient runs each test on its own event loop, so a pool
    # created by test N is bound to a loop that is already closed by test N+1 —
    # producing ConnectionDoesNotExistError, "Event loop is closed", and
    # "another operation is in progress" rather than any real assertion failure.
    # Clearing the globals makes each test build its own pool on its own loop.
    #
    # The creation lock needs no reset here: api_compat builds it lazily per
    # running loop precisely because an asyncio.Lock binds to the loop that
    # first awaits it, which is the same hazard this comment describes.
    monkeypatch.setattr(api_compat, "_pool", None)
    monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.UNKNOWN)
    monkeypatch.setattr(api_compat, "_pool_retry_after", 0.0)

    # Block external network, but NOT the database this tier exists to exercise.
    #
    # This guard was copied from tier 1, where blocking every connect() is right
    # because tier 1 talks to nothing. Tier 2 must reach Postgres, so the blanket
    # ban made the whole tier error out in setup — which is why it had never run.
    #
    # "External" means anything that is not the configured database. Loopback is
    # allowed because the DSN commonly points at a port-forward or a local
    # container; a real outbound call still fails and names the address it tried.
    real_connect = socket.socket.connect
    allowed_hosts = {"127.0.0.1", "::1", "localhost"}
    dsn_host = urlparse(settings.database_url).hostname if settings.database_url else None
    if dsn_host:
        allowed_hosts.add(dsn_host)

    def reject_external_network(self: socket.socket, address: Any, *args: Any, **kwargs: Any) -> None:
        host = address[0] if isinstance(address, tuple) and address else address
        if host in allowed_hosts:
            return real_connect(self, address, *args, **kwargs)
        raise AssertionError(
            f"external network access is forbidden in integration tests (tried {host!r}); "
            f"only the database and loopback are permitted"
        )

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    from main import app

    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


# ---------------------------------------------------------------------------
# Endpoint table (mirrors tier 1)
# ---------------------------------------------------------------------------

# Identifiers of rows data-mock.sql actually inserts.
#
# These were previously "tenant-a:agent-1", "tenant-a:violation-1" and
# "tenant-a:nhi-1" -- the composite ids api_compat manufactures in its in-memory
# fixture store. No such id can exist in Postgres, where every primary key is a
# UUID, so the handlers correctly rejected them: enroll and dismiss returned the
# 404 their non-UUID guard is there to produce.
#
# The masking is worth naming. get_agent and transition_agent do not 404 on an
# unknown id, they synthesise a plausible agent, so "GET agent" passed against a
# row that did not exist and the transition round-trip failed only at the final
# assertion. See the report: that fallback is a product concern, not a test one.
SEEDED_TENANT = "tenant-demo"
_SEEDED_AGENT_ID = "a0000000-0000-0000-0000-000000000001"      # sir-lancelot
_SEEDED_VIOLATION_ID = "b0000000-0000-0000-0000-000000000001"  # no_identity, new
_SEEDED_NHI_ACCOUNT_ID = "e0000000-0000-0000-0000-000000000001"  # svc-salesforce-sync

ENDPOINT_TABLE: list[tuple[str, str, dict[str, Any] | None, type[BaseModel] | None, str]] = [
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
    # "initial API key" is not in this table: against the seeded tenant it is a
    # 409, not a 200, because data-mock.sql already gives tenant-demo an active
    # key. Both branches are covered by test_initial_api_key_conflicts_when_one_exists.
    ("POST", f"/api/tenants/{SEEDED_TENANT}/api-keys/rotate", None, RotateApiKeyResponse, "rotate API key"),
    ("GET", "/api/consent/status", None, ConsentStatusResponse, "consent status"),
    ("POST", "/api/consent/accept", {"document_versions": {"tos": "2026-01", "privacy": "2026-01"}, "cookie_preferences": {"strictly_necessary": True, "analytics": False}, "b2b_warranty_accepted": True}, ConsentAcceptResponse, "accept consent"),
    ("GET", "/api/cookie-preferences", None, CookiePreferencesResponse, "cookie preferences"),
    ("PATCH", "/api/cookie-preferences", {"analytics": True}, CookiePreferencesResponse, "patch cookie prefs"),
    ("GET", "/api/health/crypto", None, CryptoHealthResponse, "crypto health"),
]


def _endpoint_id(val: tuple) -> str:
    method, path, _body, _model, desc = val
    return f"{method} {path} ({desc})"


# ---------------------------------------------------------------------------
# Tier 2: Contract validation against live database
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("endpoint", ENDPOINT_TABLE, ids=_endpoint_id)
def test_integration_contract_shape(client: TestClient, endpoint: tuple) -> None:
    """Hit each endpoint against the real stack and validate the response shape."""
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
# Mutation round-trip tests
# ---------------------------------------------------------------------------

def test_create_agent_round_trip(client: TestClient) -> None:
    """POST /api/agents creates an agent; GET /api/agents/{id} retrieves it."""
    headers = _bearer(_token_for("alice"))
    create_resp = client.post(
        "/api/agents",
        json={"name": "Roundtrip Agent", "type": "Custom", "owner": "test@example.com"},
        headers=headers,
    )
    assert create_resp.status_code == 200
    created = AgentResponse.model_validate(create_resp.json())

    get_resp = client.get(f"/api/agents/{created.id}", headers=headers)
    assert get_resp.status_code == 200
    fetched = AgentResponse.model_validate(get_resp.json())
    assert fetched.name == "Roundtrip Agent"
    assert fetched.lifecycle_state == "registered"


def test_transition_agent_round_trip(client: TestClient) -> None:
    """POST transition, then GET to confirm state changed."""
    headers = _bearer(_token_for("alice"))

    transition_resp = client.post(
        f"/api/agents/{_SEEDED_AGENT_ID}/transition",
        json={"to_state": "decommissioned", "reason": "integration test"},
        headers=headers,
    )
    assert transition_resp.status_code == 200
    transition = TransitionResponse.model_validate(transition_resp.json())
    assert transition.to_state == "decommissioned"

    get_resp = client.get(f"/api/agents/{_SEEDED_AGENT_ID}", headers=headers)
    assert get_resp.status_code == 200
    agent = AgentResponse.model_validate(get_resp.json())
    assert agent.lifecycle_state == "decommissioned"


def test_consent_accept_round_trip(client: TestClient) -> None:
    """POST consent/accept, then GET consent/status to confirm persistence."""
    headers = _bearer(_token_for("alice"))

    accept_resp = client.post(
        "/api/consent/accept",
        json={
            "document_versions": {"tos": "2026-01", "privacy": "2026-01"},
            "cookie_preferences": {"strictly_necessary": True, "analytics": True},
            "b2b_warranty_accepted": True,
        },
        headers=headers,
    )
    assert accept_resp.status_code == 200
    accepted = ConsentAcceptResponse.model_validate(accept_resp.json())
    assert accepted.accepted is True

    status_resp = client.get("/api/consent/status", headers=headers)
    assert status_resp.status_code == 200
    status = ConsentStatusResponse.model_validate(status_resp.json())
    assert status.accepted is True
    assert status.cookie_preferences.analytics is True


def test_enroll_then_dismiss_nhi_round_trip(client: TestClient) -> None:
    """Enroll an NHI account, then dismiss it, confirm status at each step."""
    headers = _bearer(_token_for("alice"))
    acct = _SEEDED_NHI_ACCOUNT_ID

    enroll_resp = client.post(f"/api/nhi/discovered/{acct}/enroll", headers=headers)
    assert enroll_resp.status_code == 200
    assert enroll_resp.json()["status"] == "enrollment_requested"

    dismiss_resp = client.post(f"/api/nhi/discovered/{acct}/dismiss", headers=headers)
    assert dismiss_resp.status_code == 200
    assert dismiss_resp.json()["status"] == "dismissed"


def test_initial_api_key_conflicts_when_one_exists(client: TestClient) -> None:
    """The first key is issued; a second 'initial' call is a 409, not a 500.

    ``uq_tenant_api_keys_active`` allows one unrevoked key per tenant. bob's
    tenant-b has no seeded key, so the issue path runs and its shape is checked.
    alice's tenant-demo does, so the same call must be refused -- and refused
    with a conflict rather than the UniqueViolationError-driven 500 it used to
    return.
    """
    issued = client.post(
        "/api/tenants/tenant-b/api-keys/initial", headers=_bearer(_token_for("bob")),
    )
    assert issued.status_code == 200, issued.text
    InitialApiKeyResponse.model_validate(issued.json())

    conflict = client.post(
        f"/api/tenants/{SEEDED_TENANT}/api-keys/initial", headers=_bearer(_token_for("alice")),
    )
    assert conflict.status_code == 409, conflict.text
    assert conflict.json()["error"]["code"] == "api_key_exists"


def test_compliance_frameworks_list_validates(client: TestClient) -> None:
    """GET /api/compliance/frameworks returns a list of FrameworkResponse."""
    response = client.get("/api/compliance/frameworks", headers=_bearer(_token_for("alice")))
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    for fw in data:
        FrameworkResponse.model_validate(fw)
