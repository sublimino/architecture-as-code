"""An onboarding row must be able to say who completed onboarding.

``_terminal_transition`` is otherwise exemplary -- it audits inside ``_write``,
and only when the ``UPDATE`` actually moved a row -- but it passed
``actor=ACTOR``, a module constant reading ``"onboarding-api"``. So every
``onboarding_completed`` and ``onboarding_skipped`` row in the product answered
"who did this" with the name of a service.

That matters more here than almost anywhere else in the API.
``tenant_onboarding`` holds only the terminal state, so the ``audit_events``
row is the *sole* durable evidence the transition ever happened. There is no
second record to cross-check against, and the one that exists is
unattributable.

``test_no_audit_call_site_hardcodes_its_actor`` did not catch it, and was
written for exactly this defect. It matches ``ast.Constant`` at the call site,
and ``ACTOR`` is an ``ast.Name`` -- one hop of constant indirection walks
straight through. Its own failure message already prescribes the fix it could
not detect the need for: "authenticated_principal is authenticated_tenant's own
dependency, so a handler that only has the tenant can swap to it without
changing which tenant it resolves." That is precisely what this does.

These tests drive the pooled path, because the fixture path writes no audit row
at all -- so a test of the actor has to supply a pool to have a row to assert
on.
"""
from __future__ import annotations

import socket
import time
from contextlib import asynccontextmanager
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import onboarding
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

SUBJECT_TENANTS = {"onb-actor": "tenant-onb-actor", "onb-actor-nomail": "tenant-onb-actor"}
OPERATOR_EMAIL = "operator@signalloom.local"


def _bearer(subject: str = "onb-actor", email: str | None = OPERATOR_EMAIL) -> dict[str, str]:
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
    }
    if email is not None:
        claims["email"] = email
    token = jwt.encode(
        claims, TEST_SIGNING_KEY, algorithm="RS256",
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


class _AuditSpy:
    """Captures what reached ``_audit_log``, which is the whole assertion."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    async def __call__(self, _executor: Any, **kwargs: Any) -> None:
        self.calls.append(kwargs)


@pytest.fixture
def audit() -> _AuditSpy:
    return _AuditSpy()


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch, audit: _AuditSpy) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    # A pool, so the audit branch is reached at all. Everything it touches is
    # stubbed: this file is about which actor is recorded, not about SQL.
    moved_row = {
        "tenant_id": "tenant-onb-actor", "status": "completed",
        "skipped_at": None, "completed_at": None,
    }

    class _Conn:
        async def fetchrow(self, *_a: Any, **_k: Any) -> dict[str, Any]:
            return moved_row

        async def execute(self, *_a: Any, **_k: Any) -> None:
            return None

    @asynccontextmanager
    async def _fake_write(_pool: Any) -> Any:
        yield _Conn()

    async def _fake_get_pool() -> Any:
        return _ReadyPool()

    async def _fake_ensure_row(_pool: Any, _tenant: str) -> dict[str, Any]:
        return moved_row

    monkeypatch.setattr(onboarding, "_get_pool", _fake_get_pool)
    monkeypatch.setattr(onboarding, "_write", _fake_write)
    monkeypatch.setattr(onboarding, "_ensure_row", _fake_ensure_row)
    monkeypatch.setattr(onboarding, "_audit_log", audit)

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


def test_completing_onboarding_records_the_operator(
    client: TestClient, audit: _AuditSpy,
) -> None:
    """Asserted positively: equal to the token's identity, not merely unequal.

    "is not onboarding-api" would pass against any other constant, including
    the ``demo-actor`` literal that made thirty-four rows unattributable.
    """
    response = client.post("/api/onboarding/complete", headers=_bearer())

    assert response.status_code == 200, response.text
    assert audit.calls, "the transition wrote no audit row"
    assert audit.calls[0]["actor"] == OPERATOR_EMAIL
    assert audit.calls[0]["event_type"] == "onboarding_completed"


def test_skipping_onboarding_records_the_operator(
    client: TestClient, audit: _AuditSpy,
) -> None:
    response = client.post("/api/onboarding/skip", headers=_bearer())

    assert response.status_code == 200, response.text
    assert audit.calls[0]["actor"] == OPERATOR_EMAIL
    assert audit.calls[0]["event_type"] == "onboarding_skipped"


def test_a_token_with_no_email_records_the_subject_rather_than_a_constant(
    client: TestClient, audit: _AuditSpy,
) -> None:
    """``Principal.actor`` falls back to ``sub`` when Dex grants no email scope.

    Recording the subject is honest; substituting a fixed name would put a
    fabricated identity in an audit column, which is what this fixes.
    """
    client.post(
        "/api/onboarding/complete",
        headers=_bearer(subject="onb-actor-nomail", email=None),
    )

    assert audit.calls[0]["actor"] == "onb-actor-nomail"


def test_the_service_name_is_gone_entirely(client: TestClient, audit: _AuditSpy) -> None:
    """The constant is deleted, not merely bypassed on the paths under test."""
    client.post("/api/onboarding/complete", headers=_bearer())

    assert not hasattr(onboarding, "ACTOR")
    assert audit.calls[0]["actor"] != "onboarding-api"
