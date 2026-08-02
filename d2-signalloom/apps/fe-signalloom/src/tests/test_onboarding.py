"""Contract for the onboarding status and wizard-state routes.

The dashboard shipped ``src/api/onboardingClient.ts`` against four routes that
did not exist, so the client silently fell back to MOCK_MODE — where ``skip()``
writes a module-level variable that dies on reload. "Skip for now" therefore
never persisted and ``ProtectedRoute`` bounced every non-exempt route back to
``/onboarding``, with no error anywhere. These tests pin the routes down so that
cannot recur.

Storage runs on the in-memory fixture path (no Postgres pool). The pooled path
shares the same handlers; ``test_migrations.py`` covers the schema itself.
"""
from __future__ import annotations

import socket
import time
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# One tenant per test: the in-memory store is module-level and persists for the
# whole process, so a shared tenant would leak state between assertions.
SUBJECT_TENANTS = {
    "onb-fresh": "tenant-onb-fresh",
    "onb-skip": "tenant-onb-skip",
    "onb-complete": "tenant-onb-complete",
    "onb-idempotent": "tenant-onb-idempotent",
    "onb-state": "tenant-onb-state",
    "onb-isolation-a": "tenant-onb-isolation-a",
    "onb-isolation-b": "tenant-onb-isolation-b",
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


# ─── Status ─────────────────────────────────────────────────────────────────


def test_fresh_tenant_is_pending_with_no_dates(client: TestClient) -> None:
    res = client.get("/api/onboarding/status", headers=_bearer("onb-fresh"))
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "pending"
    assert body["skipped_at"] is None
    assert body["completed_at"] is None


def test_status_requires_authentication(client: TestClient) -> None:
    assert client.get("/api/onboarding/status").status_code == 401


def test_unknown_subject_has_no_tenant(client: TestClient) -> None:
    assert client.get("/api/onboarding/status", headers=_bearer("nobody")).status_code == 403


# ─── Skip / complete ────────────────────────────────────────────────────────


def test_skip_sets_status_and_date(client: TestClient) -> None:
    res = client.post("/api/onboarding/skip", headers=_bearer("onb-skip"))
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "skipped"
    assert body["skipped_at"] is not None
    assert body["completed_at"] is None


def test_skip_persists_across_requests(client: TestClient) -> None:
    """The bug this whole module exists for: MOCK_MODE lost this on reload."""
    client.post("/api/onboarding/skip", headers=_bearer("onb-skip"))
    body = client.get("/api/onboarding/status", headers=_bearer("onb-skip")).json()
    assert body["status"] == "skipped"
    assert body["skipped_at"] is not None


def test_complete_sets_status_and_date(client: TestClient) -> None:
    body = client.post("/api/onboarding/complete", headers=_bearer("onb-complete")).json()
    assert body["status"] == "completed"
    assert body["completed_at"] is not None
    assert body["skipped_at"] is None


def test_repeat_skip_keeps_the_original_timestamp(client: TestClient) -> None:
    """A double-clicked button must not rewrite when onboarding finished."""
    first = client.post("/api/onboarding/skip", headers=_bearer("onb-idempotent")).json()
    time.sleep(0.01)
    second = client.post("/api/onboarding/skip", headers=_bearer("onb-idempotent")).json()
    assert first["skipped_at"] == second["skipped_at"]
    assert second["status"] == "skipped"


# ─── Wizard state ───────────────────────────────────────────────────────────


def test_wizard_state_defaults_are_empty(client: TestClient) -> None:
    body = client.get("/api/onboarding/state", headers=_bearer("onb-state")).json()
    assert body == {"selected_provider_ids": [], "step_index": 0, "provider_run_state": {}}


def test_wizard_state_round_trips(client: TestClient) -> None:
    state = {
        "selected_provider_ids": ["okta", "entra"],
        "step_index": 2,
        "provider_run_state": {
            "okta": {"status": "connected", "error": None},
            "entra": {"status": "error", "error": "invalid client secret"},
        },
    }
    put = client.put("/api/onboarding/state", json=state, headers=_bearer("onb-state"))
    assert put.status_code == 200

    got = client.get("/api/onboarding/state", headers=_bearer("onb-state")).json()
    assert got["selected_provider_ids"] == ["okta", "entra"]
    assert got["step_index"] == 2
    assert got["provider_run_state"]["entra"]["error"] == "invalid client secret"


def test_wizard_state_rejects_a_malformed_body(client: TestClient) -> None:
    res = client.put(
        "/api/onboarding/state",
        json={"step_index": "not-a-number"},
        headers=_bearer("onb-state"),
    )
    assert res.status_code == 422


# ─── Tenancy ────────────────────────────────────────────────────────────────


def test_one_tenant_skip_does_not_leak_to_another(client: TestClient) -> None:
    """Isolation is enforced by the handler, not by the caller.

    tenant_id comes from a server-side subject→tenant map, never from a claim
    the client controls, so this is the boundary that matters most here.
    """
    client.post("/api/onboarding/skip", headers=_bearer("onb-isolation-a"))

    a = client.get("/api/onboarding/status", headers=_bearer("onb-isolation-a")).json()
    b = client.get("/api/onboarding/status", headers=_bearer("onb-isolation-b")).json()

    assert a["status"] == "skipped"
    assert b["status"] == "pending"
    assert b["skipped_at"] is None


def test_wizard_state_does_not_leak_between_tenants(client: TestClient) -> None:
    client.put(
        "/api/onboarding/state",
        json={"selected_provider_ids": ["okta"], "step_index": 3, "provider_run_state": {}},
        headers=_bearer("onb-isolation-a"),
    )
    b = client.get("/api/onboarding/state", headers=_bearer("onb-isolation-b")).json()
    assert b["selected_provider_ids"] == []
    assert b["step_index"] == 0
