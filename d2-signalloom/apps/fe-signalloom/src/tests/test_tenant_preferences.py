"""Scan-preference contract for PATCH /api/tenant/settings/preferences.

The onboarding wizard's "Set your scan preferences" step used to fail with a
404 because the route the dashboard was written against never existed.  These
tests pin the route down on both storage paths: the in-memory fixture store
(no Postgres pool) and the pooled path (exercised through a recording fake
pool, so the assertions stay hermetic).
"""
from __future__ import annotations

import copy
import json
import logging
import socket
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from types import SimpleNamespace
from typing import Any

import asyncpg
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

from tests.contract import TenantSettingsResponse

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# Each subject maps to its own tenant: the in-memory stores are module-level
# and persist for the whole process, so tests that assert on defaults need a
# tenant no other test has written to.
SUBJECT_TENANTS = {
    "prefs-fresh": "tenant-prefs-fresh",
    "prefs-roundtrip": "tenant-prefs-roundtrip",
    "prefs-email": "tenant-prefs-email",
    "prefs-invalid": "tenant-prefs-invalid",
    "prefs-pooled": "tenant-prefs-pooled",
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
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def _bearer(subject: str) -> dict[str, str]:
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
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


# ---------------------------------------------------------------------------
# In-memory fallback path (api_compat._get_pool() returns None)
# ---------------------------------------------------------------------------

def test_patch_preferences_is_routed_and_returns_the_updated_values(client: TestClient) -> None:
    """Regression guard: this used to be a 404 -- the route did not exist."""
    response = client.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 6,
            "alert_email": "alerts@signalloom.local",
            "alert_threshold": 4,
        },
        headers=_bearer("prefs-roundtrip"),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["preferred_scan_cadence_hours"] == 6
    assert body["alert_email"] == "alerts@signalloom.local"
    assert body["alert_threshold"] == 4


def test_patch_preferences_response_validates_against_the_consumer_contract(client: TestClient) -> None:
    response = client.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 6,
            "alert_email": "alerts@signalloom.local",
            "alert_threshold": 4,
        },
        headers=_bearer("prefs-roundtrip"),
    )

    assert response.status_code == 200, response.text
    # extra="forbid" on both sides, so this fails if either model drifts.
    settings_model = TenantSettingsResponse.model_validate(response.json())
    assert settings_model.preferred_scan_cadence_hours == 6
    assert settings_model.alert_email == "alerts@signalloom.local"
    assert settings_model.alert_threshold == 4


def test_get_settings_returns_documented_defaults_for_a_fresh_tenant(client: TestClient) -> None:
    response = client.get("/api/tenant/settings", headers=_bearer("prefs-fresh"))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["preferred_scan_cadence_hours"] == 24
    assert body["alert_email"] is None
    assert body["alert_threshold"] == 1
    TenantSettingsResponse.model_validate(body)


def test_patch_then_get_round_trips_the_written_values(client: TestClient) -> None:
    patched = client.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 168,
            "alert_email": "weekly@signalloom.local",
            "alert_threshold": 9,
        },
        headers=_bearer("prefs-roundtrip"),
    )
    assert patched.status_code == 200, patched.text

    fetched = client.get("/api/tenant/settings", headers=_bearer("prefs-roundtrip"))
    assert fetched.status_code == 200, fetched.text
    body = fetched.json()
    assert body["preferred_scan_cadence_hours"] == 168
    assert body["alert_email"] == "weekly@signalloom.local"
    assert body["alert_threshold"] == 9


@pytest.mark.parametrize("alert_email", [None, "", "   "])
def test_absent_alert_email_is_accepted_and_normalised_to_null(
    client: TestClient, alert_email: str | None,
) -> None:
    """The wizard sends `alert_email || null`; the Settings view can send ''."""
    response = client.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 24,
            "alert_email": alert_email,
            "alert_threshold": 1,
        },
        headers=_bearer("prefs-email"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["alert_email"] is None


@pytest.mark.parametrize(
    "body",
    [
        {"preferred_scan_cadence_hours": 0, "alert_email": None, "alert_threshold": 1},
        {"preferred_scan_cadence_hours": -12, "alert_email": None, "alert_threshold": 1},
        {"preferred_scan_cadence_hours": 1.5, "alert_email": None, "alert_threshold": 1},
        {"preferred_scan_cadence_hours": "soon", "alert_email": None, "alert_threshold": 1},
        {"preferred_scan_cadence_hours": 24, "alert_email": None, "alert_threshold": 0},
        {"preferred_scan_cadence_hours": 24, "alert_email": None, "alert_threshold": -3},
        {"preferred_scan_cadence_hours": 24, "alert_email": None, "alert_threshold": 2.5},
        {"preferred_scan_cadence_hours": 24, "alert_email": None, "alert_threshold": "many"},
    ],
    ids=[
        "cadence-zero", "cadence-negative", "cadence-fractional", "cadence-not-a-number",
        "threshold-zero", "threshold-negative", "threshold-fractional", "threshold-not-a-number",
    ],
)
def test_nonsense_values_are_rejected_with_422(client: TestClient, body: dict[str, Any]) -> None:
    response = client.patch(
        "/api/tenant/settings/preferences", json=body, headers=_bearer("prefs-invalid"),
    )

    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == "invalid_request"


def test_rejected_preferences_are_not_stored(client: TestClient) -> None:
    client.patch(
        "/api/tenant/settings/preferences",
        json={"preferred_scan_cadence_hours": 0, "alert_email": None, "alert_threshold": 0},
        headers=_bearer("prefs-invalid"),
    )

    body = client.get("/api/tenant/settings", headers=_bearer("prefs-invalid")).json()
    assert body["preferred_scan_cadence_hours"] == 24
    assert body["alert_threshold"] == 1


def test_unknown_preference_fields_are_rejected(client: TestClient) -> None:
    response = client.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 24,
            "alert_email": None,
            "alert_threshold": 1,
            "scan_on_tuesdays": True,
        },
        headers=_bearer("prefs-invalid"),
    )

    assert response.status_code == 422, response.text


# ---------------------------------------------------------------------------
# Pooled path, driven through a recording fake pool
# ---------------------------------------------------------------------------

class _FakeConnection:
    """The connection ``api_compat._write()`` yields.

    Statement handling is the pool's; what a connection adds is a transaction
    whose rollback actually undoes the writes staged inside it.
    """

    def __init__(self, pool: "_FakePool") -> None:
        self._pool = pool

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        return await self._pool.fetchrow(query, *args)

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        return await self._pool.fetch(query, *args)

    async def execute(self, query: str, *args: Any) -> None:
        await self._pool.execute(query, *args)

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[None]:
        snapshot = self._pool.snapshot()
        try:
            yield
        except BaseException:
            self._pool.restore(snapshot)
            raise


class _FakePool:
    """Minimal asyncpg.Pool stand-in for the tenant_settings read/write path.

    Rows are plain dicts, which satisfies both ``row["col"]`` and
    ``row.get("col")`` exactly as ``asyncpg.Record`` does.
    """

    def __init__(self) -> None:
        self.tenant_settings: dict[str, dict[str, Any]] = {}
        self.audit_events: list[dict[str, Any]] = []

    @asynccontextmanager
    async def acquire(self) -> AsyncIterator[_FakeConnection]:
        yield _FakeConnection(self)

    def snapshot(self) -> tuple[Any, Any]:
        return copy.deepcopy(self.tenant_settings), copy.deepcopy(self.audit_events)

    def restore(self, snapshot: tuple[Any, Any]) -> None:
        self.tenant_settings, self.audit_events = snapshot

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        if "FROM tenant_settings" in query:
            return self.tenant_settings.get(args[0])
        if "FROM agent_registry" in query:
            return {"cnt": 0}
        if "FROM consent_events" in query:
            return None
        raise AssertionError(f"unexpected fetchrow: {query}")

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        raise AssertionError(f"unexpected fetch: {query}")

    async def execute(self, query: str, *args: Any) -> None:
        if query.startswith("INSERT INTO tenant_settings"):
            tenant_id, org_name = args
            self.tenant_settings.setdefault(
                tenant_id,
                {
                    "tenant_id": tenant_id,
                    "org_name": org_name,
                    "plan_tier": "enterprise",
                    "api_key_status": "active",
                    "selected_frameworks": ["eu-ai-act"],
                    "consent_accepted_at": None,
                    "cookie_preferences": None,
                    "preferred_scan_cadence_hours": 24,
                    "alert_email": None,
                    "alert_threshold": 1,
                },
            )
            return
        if "UPDATE tenant_settings" in query and "preferred_scan_cadence_hours" in query:
            cadence, alert_email, threshold, tenant_id = args
            row = self.tenant_settings[tenant_id]
            if "preferred_scan_cadence_hours" not in row:
                # What a real pre-migration database does.
                raise asyncpg.UndefinedColumnError(
                    'column "preferred_scan_cadence_hours" of relation '
                    '"tenant_settings" does not exist',
                )
            row["preferred_scan_cadence_hours"] = cadence
            row["alert_email"] = alert_email
            row["alert_threshold"] = threshold
            return
        if "INSERT INTO audit_events" in query:
            tenant_id, event_type, _agent_id, _agent_name, actor, detail = args
            self.audit_events.append(
                {
                    "tenant_id": tenant_id,
                    "event_type": event_type,
                    "actor": actor,
                    "detail": json.loads(detail),
                },
            )
            return
        raise AssertionError(f"unexpected execute: {query}")


@pytest.fixture
def pooled_client(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> tuple[TestClient, _FakePool]:
    pool = _FakePool()

    async def _fake_get_pool() -> _FakePool:
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _fake_get_pool)
    return client, pool


def test_pooled_path_persists_and_returns_the_same_shape_as_the_fallback(
    pooled_client: tuple[TestClient, _FakePool],
) -> None:
    http, pool = pooled_client

    defaults = http.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))
    assert defaults.status_code == 200, defaults.text
    assert defaults.json()["preferred_scan_cadence_hours"] == 24
    assert defaults.json()["alert_email"] is None
    assert defaults.json()["alert_threshold"] == 1

    patched = http.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 6,
            "alert_email": "pooled@signalloom.local",
            "alert_threshold": 4,
        },
        headers=_bearer("prefs-pooled"),
    )
    assert patched.status_code == 200, patched.text
    TenantSettingsResponse.model_validate(patched.json())
    assert patched.json()["preferred_scan_cadence_hours"] == 6
    assert patched.json()["alert_email"] == "pooled@signalloom.local"
    assert patched.json()["alert_threshold"] == 4

    stored = pool.tenant_settings["tenant-prefs-pooled"]
    assert stored["preferred_scan_cadence_hours"] == 6
    assert stored["alert_email"] == "pooled@signalloom.local"
    assert stored["alert_threshold"] == 4

    fetched = http.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))
    assert fetched.json()["preferred_scan_cadence_hours"] == 6
    assert fetched.json()["alert_email"] == "pooled@signalloom.local"
    assert fetched.json()["alert_threshold"] == 4


def test_pooled_path_writes_an_audit_event(
    pooled_client: tuple[TestClient, _FakePool],
) -> None:
    http, pool = pooled_client

    http.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 12,
            "alert_email": "audit@signalloom.local",
            "alert_threshold": 2,
        },
        headers=_bearer("prefs-pooled"),
    )

    events = [e for e in pool.audit_events if e["event_type"] == "tenant.preferences_updated"]
    assert len(events) == 1
    assert events[0]["tenant_id"] == "tenant-prefs-pooled"
    assert events[0]["actor"] == "prefs-pooled"
    assert events[0]["detail"] == {
        "preferred_scan_cadence_hours": 12,
        "alert_email": "audit@signalloom.local",
        "alert_threshold": 2,
    }


def test_pooled_path_rejects_nonsense_before_touching_the_database(
    pooled_client: tuple[TestClient, _FakePool],
) -> None:
    http, pool = pooled_client

    response = http.patch(
        "/api/tenant/settings/preferences",
        json={"preferred_scan_cadence_hours": 0, "alert_email": None, "alert_threshold": 0},
        headers=_bearer("prefs-pooled"),
    )

    assert response.status_code == 422, response.text
    assert pool.audit_events == []
    assert pool.tenant_settings == {}


# ---------------------------------------------------------------------------
# Degradation policy: serve defaults on read, but announce the substitution.
#
# Of the three options -- both endpoints degrade, both endpoints fail, or
# degrade-but-say-so -- this is the third. GET keeps working so a settings page
# does not 500 over a cadence, PATCH keeps failing loudly rather than pretending
# to persist, and every substituted value is named in a WARNING so the condition
# is visible instead of being a plausible-looking invented number.
# ---------------------------------------------------------------------------

_PRE_005_ROW = {
    "tenant_id": "tenant-prefs-pooled",
    "org_name": "Legacy Org",
    "plan_tier": "enterprise",
    "api_key_status": "active",
    "selected_frameworks": ["eu-ai-act"],
    "consent_accepted_at": None,
    "cookie_preferences": None,
}


def test_pooled_get_tolerates_a_database_that_predates_migration_005(
    pooled_client: tuple[TestClient, _FakePool],
) -> None:
    """A not-yet-migrated tenant_settings row must not turn a 404 into a 500."""
    http, pool = pooled_client
    pool.tenant_settings["tenant-prefs-pooled"] = dict(_PRE_005_ROW)

    response = http.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["preferred_scan_cadence_hours"] == 24
    assert body["alert_email"] is None
    assert body["alert_threshold"] == 1


def test_pooled_get_announces_that_it_is_serving_defaults(
    pooled_client: tuple[TestClient, _FakePool],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Substituting a default is fine; substituting it silently is not."""
    http, pool = pooled_client
    pool.tenant_settings["tenant-prefs-pooled"] = dict(_PRE_005_ROW)

    with caplog.at_level(logging.WARNING, logger="api_compat"):
        http.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))

    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert warnings, "a degraded read must be visible in the logs"
    message = warnings[0].getMessage()
    assert "tenant-prefs-pooled" in message
    assert "preferred_scan_cadence_hours" in message
    assert "alert_email" in message
    assert "alert_threshold" in message
    assert "NOT stored values" in message
    assert "005_tenant_scan_preferences" in message


def test_a_healthy_read_logs_no_warning(
    pooled_client: tuple[TestClient, _FakePool],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """The warning must mean something, so a migrated database must be silent."""
    http, _pool = pooled_client

    with caplog.at_level(logging.WARNING, logger="api_compat"):
        response = http.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))

    assert response.status_code == 200, response.text
    assert [r for r in caplog.records if r.levelno == logging.WARNING] == []


def test_a_stored_null_alert_email_is_not_reported_as_missing(
    pooled_client: tuple[TestClient, _FakePool],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """NULL is a legitimate alert_email, unlike a column that is not there."""
    http, pool = pooled_client
    row = dict(_PRE_005_ROW)
    row.update(
        preferred_scan_cadence_hours=6, alert_email=None, alert_threshold=2,
    )
    pool.tenant_settings["tenant-prefs-pooled"] = row

    with caplog.at_level(logging.WARNING, logger="api_compat"):
        response = http.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))

    assert response.json()["alert_email"] is None
    assert [r for r in caplog.records if r.levelno == logging.WARNING] == []


def test_both_storage_paths_degrade_identically(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture,
) -> None:
    """The in-memory path and the pooled path must not disagree under the same fault."""
    # In-memory store with the preferences entry absent.
    client.get("/api/tenant/settings", headers=_bearer("prefs-fresh"))
    monkeypatch.delitem(api_compat._TENANT_PREFERENCES, "tenant-prefs-fresh")
    with caplog.at_level(logging.WARNING, logger="api_compat"):
        in_memory = client.get("/api/tenant/settings", headers=_bearer("prefs-fresh"))
    in_memory_warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]

    # Pooled path with the columns absent.
    pool = _FakePool()
    pool.tenant_settings["tenant-prefs-pooled"] = dict(_PRE_005_ROW)

    async def _fake_get_pool() -> _FakePool:
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _fake_get_pool)
    caplog.clear()
    with caplog.at_level(logging.WARNING, logger="api_compat"):
        pooled = client.get("/api/tenant/settings", headers=_bearer("prefs-pooled"))
    pooled_warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]

    assert in_memory.status_code == pooled.status_code == 200
    for field in ("preferred_scan_cadence_hours", "alert_email", "alert_threshold"):
        assert in_memory.json()[field] == pooled.json()[field]
    assert len(in_memory_warnings) == len(pooled_warnings) == 1
    for column in ("preferred_scan_cadence_hours", "alert_email", "alert_threshold"):
        assert column in in_memory_warnings[0]
        assert column in pooled_warnings[0]


def test_patch_still_fails_loudly_when_the_columns_are_absent(
    pooled_client: tuple[TestClient, _FakePool],
) -> None:
    """Read degrades; write does not pretend. The pair is honest either way."""
    http, pool = pooled_client
    pool.tenant_settings["tenant-prefs-pooled"] = dict(_PRE_005_ROW)

    response = http.patch(
        "/api/tenant/settings/preferences",
        json={
            "preferred_scan_cadence_hours": 6,
            "alert_email": "nope@signalloom.local",
            "alert_threshold": 2,
        },
        headers=_bearer("prefs-pooled"),
    )

    assert response.status_code == 500, response.text
    assert response.json()["error"]["code"] == "internal_error"
    stored = pool.tenant_settings["tenant-prefs-pooled"]
    assert "preferred_scan_cadence_hours" not in stored
