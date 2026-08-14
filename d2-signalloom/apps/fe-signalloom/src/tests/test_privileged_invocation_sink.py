"""The endpoint that persists a privileged demo invocation for the runner.

``POST /api/audit/privileged-invocations`` is the one place in this API that
records something it did not itself perform, and it exists because the
supercred-demo-runner has no database and must not be given one. Being the
exception, it carries the tightest contract: the reporter supplies two values
from closed sets and nothing else, and every field that makes the row worth
having is derived here from a token this process validated.

These tests are the contract. They exist to catch the drift that would make
this endpoint what the stun endpoint used to be -- a service that writes down
whatever it is told.
"""
from __future__ import annotations

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

SUBJECT_TENANTS = {"demo-sink": "tenant-demo-sink"}
TENANT = "tenant-demo-sink"
SUPERADMIN_EMAIL = "instructor-sink@signalloom.local"
ENDPOINT = "/api/audit/privileged-invocations"


def _bearer(email: str = SUPERADMIN_EMAIL) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": "demo-sink",
            "email": email,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


class _ReadyPool:
    async def close(self) -> None:
        pass


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(settings, "api_superadmin_emails", {SUPERADMIN_EMAIL})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    api_compat.reset_tenant_state(TENANT)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT)


def _audit_events(client: TestClient) -> list[dict[str, Any]]:
    return client.get("/api/audit", headers=_bearer()).json()["events"]


def _demo_events(client: TestClient) -> list[dict[str, Any]]:
    """Only what this endpoint wrote.

    The fixture path seeds three unrelated events per tenant, so an assertion
    that the whole list is empty tests the seed rather than the endpoint.
    """
    return [e for e in _audit_events(client) if e["event_type"].startswith("demo.")]


def test_a_reported_phase_run_is_persisted(client: TestClient) -> None:
    response = client.post(
        ENDPOINT, json={"step_id": "4", "kind": "step"}, headers=_bearer(),
    )

    assert response.status_code == 201, response.text
    event = _audit_events(client)[0]
    assert event["event_type"] == "demo.phase_run"
    assert event["detail"]["step_id"] == "4"


def test_a_reported_reset_is_persisted_under_its_own_event_type(
    client: TestClient,
) -> None:
    """Derived from `kind`, so the reporter cannot choose which row it writes."""
    response = client.post(
        ENDPOINT, json={"step_id": "5", "kind": "reset"}, headers=_bearer(),
    )

    assert response.status_code == 201, response.text
    event = _audit_events(client)[0]
    assert event["event_type"] == "demo.reset_requested"
    assert event["detail"]["preempts_active_run"] is True


def test_the_actor_comes_from_the_token_and_cannot_be_supplied(
    client: TestClient,
) -> None:
    """The field the browser used to author, now unreachable from the wire."""
    response = client.post(
        ENDPOINT,
        json={"step_id": "4", "kind": "step", "actor": "someone-else@evil.test"},
        headers=_bearer(),
    )

    assert response.status_code == 422, response.text
    assert _demo_events(client) == []

    accepted = client.post(
        ENDPOINT, json={"step_id": "4", "kind": "step"}, headers=_bearer(),
    )
    assert accepted.json()["actor"] == SUPERADMIN_EMAIL


@pytest.mark.parametrize(
    "forbidden",
    [
        {"event_type": "agent.stunned"},
        {"outcome": "stunned"},
        {"reason": "because I said so"},
        {"reported_by": "not-the-runner"},
        {"observed": True},
    ],
)
def test_no_audit_field_may_be_supplied_by_the_caller(
    client: TestClient, forbidden: dict[str, Any],
) -> None:
    """`extra="forbid"`, asserted per field rather than trusted as a setting.

    Each of these is a field the row carries. A caller who can set any one of
    them can make the row say something nobody checked, which is the whole of
    what this branch was written to stop.
    """
    response = client.post(
        ENDPOINT, json={"step_id": "4", "kind": "step", **forbidden}, headers=_bearer(),
    )

    assert response.status_code == 422, response.text


def test_the_row_says_it_was_reported_rather_than_observed(
    client: TestClient,
) -> None:
    """Honesty about which kind of fact this is.

    This process validated the identity, so the actor is first-party. It did
    not run the script and cannot see the cluster, so the row says so in the
    payload instead of leaving a reader to assume otherwise.
    """
    response = client.post(
        ENDPOINT, json={"step_id": "4", "kind": "step"}, headers=_bearer(),
    )

    detail = response.json()["detail"]
    assert detail["reported_by"] == "supercred-demo-runner"
    assert detail["observed"] is False
    assert "outcome" not in detail


def test_an_unknown_step_is_refused(client: TestClient) -> None:
    """The closed set is the only constraint available on a reported value.

    ``step_id`` is the one field that cannot be verified here -- only the
    runner knows which phase it was asked for. Pinning it to the same literal
    set the runner accepts at least stops the row naming a phase that does not
    exist.
    """
    response = client.post(
        ENDPOINT, json={"step_id": "99", "kind": "step"}, headers=_bearer(),
    )

    assert response.status_code == 422, response.text
    assert _demo_events(client) == []


def test_a_non_superadmin_cannot_write_a_privileged_invocation(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Same gate as the control it records, for the same reason.

    The residual exposure this endpoint accepts is that a caller entitled to
    press the button could report a press that never happened. That trade only
    holds while the callers are exactly that set.
    """
    monkeypatch.setattr(settings, "api_superadmin_emails", {"someone-else@signalloom.local"})

    response = client.post(
        ENDPOINT, json={"step_id": "4", "kind": "step"}, headers=_bearer(),
    )

    assert response.status_code == 403, response.text
    assert _demo_events(client) == []


def test_an_unauthenticated_caller_is_refused(client: TestClient) -> None:
    response = client.post(ENDPOINT, json={"step_id": "4", "kind": "step"})

    assert response.status_code == 401, response.text
