"""SLAAT-P2-2: Backend API auth hardening, tenant IDOR, and enrollment fixes.

Regression coverage for the vulnerabilities SLAAT-P1-2/P2-PRE found and this
card remediates:

1. ``POST /api/v1/compliance/posture/calculate`` and
   ``POST /api/v1/policies/validate`` had no authentication dependency at
   all -- reachable with zero credentials.  The generic
   ``test_unauthenticated_mutation_fails_closed`` sweep in
   ``test_adversarial_api_security.py`` could not have caught this on its
   own: it accepts 422 as a passing outcome (legitimate for a validation
   endpoint), and both handlers return 422 for a malformed/empty body
   regardless of authentication -- so a missing auth dependency hides behind
   a coincidentally-identical status code unless the probe payload is
   well-formed enough to succeed were it not for the auth gate.  These tests
   send exactly such a payload.
2. ``GET /api/v1/discovery/workloads`` (the ``routers/discovery.py`` mount)
   forwarded to ``api_compat.list_discovery_workloads`` with
   ``request=request, principal=principal, ...`` -- kwargs that function has
   never accepted (it takes ``tenant_id: Depends(authenticated_tenant)``).
   Every authenticated call raised ``TypeError`` inside route dispatch,
   which FastAPI's exception middleware turned into an unhandled 500 --
   failing open on an exception, not failing closed. Fixed by deriving
   ``tenant_id`` from the already-authenticated ``principal`` and calling
   the real signature.
"""
from __future__ import annotations

import socket
import time
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from external_agent_registration import reset_external_agent_state
from host_enrollment import reset_host_enrollment_state
from main import app

_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE, TENANT_A = "remediation-alice", "remediation-tenant-a"
BOB, TENANT_B = "remediation-bob", "remediation-tenant-b"


def _token(subject: str) -> str:
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
        _SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "remediation-key", "typ": "JWT"},
    )


def bearer(subject: str = ALICE) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token(subject)}"}


class _JwkClient:
    def get_signing_key_from_jwt(self, token: str):
        from types import SimpleNamespace

        if jwt.get_unverified_header(token).get("kid") != "remediation-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=_SIGNING_KEY.public_key())


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {ALICE: TENANT_A, BOB: TENANT_B})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JwkClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    def _reject_network(*_a: Any, **_kw: Any) -> None:
        raise AssertionError("no external network in tests")

    monkeypatch.setattr(socket.socket, "connect", _reject_network)

    api_compat.reset_tenant_state(TENANT_A)
    api_compat.reset_tenant_state(TENANT_B)
    reset_external_agent_state()
    reset_host_enrollment_state()

    class _ReadyPool:
        async def close(self) -> None:
            pass

    set_pool_for_testing(_ReadyPool())
    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


# ---------------------------------------------------------------------------
# 1. Previously-unauthenticated endpoints: well-formed payload, no credentials
# ---------------------------------------------------------------------------


def test_posture_calculate_requires_authentication(client: TestClient) -> None:
    """A well-formed, otherwise-200 payload must still be rejected with no Bearer token.

    Before this card: ``calculate_posture`` had no ``Depends`` at all, so this
    exact request returned 200 with ``posture_score: 100.0`` to any anonymous
    caller.
    """
    well_formed = {"total_controls": 4, "passing_controls": 4, "failing_controls": 0}
    resp = client.post("/api/v1/compliance/posture/calculate", json=well_formed)
    assert resp.status_code in (401, 403), (resp.status_code, resp.text)

    authed = client.post(
        "/api/v1/compliance/posture/calculate", json=well_formed, headers=bearer()
    )
    assert authed.status_code == 200, authed.text
    assert authed.json()["posture_score"] == 100.0


def test_policies_validate_requires_authentication(client: TestClient) -> None:
    """Same shape of regression, for the CEL syntax validator.

    Before this card: ``validate_policy_expression`` had no ``Depends`` at
    all, so a syntactically valid CEL expression returned 200 to any
    anonymous caller.
    """
    well_formed = {"expression": "true"}
    resp = client.post("/api/v1/policies/validate", json=well_formed)
    assert resp.status_code in (401, 403), (resp.status_code, resp.text)

    authed = client.post("/api/v1/policies/validate", json=well_formed, headers=bearer())
    assert authed.status_code == 200, authed.text
    assert authed.json()["valid"] is True


# ---------------------------------------------------------------------------
# 2. GET /api/v1/discovery/workloads: TypeError -> 500 on every authenticated call
# ---------------------------------------------------------------------------


def test_discovery_workloads_v1_mount_does_not_crash(client: TestClient) -> None:
    """The ``routers/discovery.py`` mount must forward to the real api_compat
    signature, not 500 on every authenticated call.

    Before this card: ``list_discovery_workloads`` in ``routers/discovery.py``
    called ``api_compat.list_discovery_workloads(request=request,
    principal=principal, ...)`` -- kwargs the target function has never
    accepted (it takes ``tenant_id: Depends(authenticated_tenant)``) -- so
    every call raised ``TypeError`` inside route dispatch, which FastAPI
    turned into an unhandled 500.  A route that always 500s fails OPEN on an
    exception, not closed; nothing about it ever actually read or filtered
    the ``agent_registry``/``nhi_discovered_accounts`` tables it was meant to
    scope by tenant.
    """
    resp = client.get("/api/v1/discovery/workloads", headers=bearer())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert "workloads" in body and "total" in body and "summary" in body


def test_discovery_workloads_v1_mount_is_tenant_isolated(client: TestClient) -> None:
    """Once the crash is fixed, confirm the route it was forwarding to is
    actually tenant-scoped (duplicate assertion of the DB_ROUTES sweep in
    ``test_tenant_isolation.py``, pinned here next to the bug it regresses)."""
    api_compat.set_tenant_connectors_for_testing(TENANT_A, {"idp": False, "local_k8s": False, "external_k8s": False, "external_services": False})
    api_compat.set_tenant_connectors_for_testing(TENANT_B, {"idp": False, "local_k8s": False, "external_k8s": False, "external_services": False})
    try:
        alice_resp = client.get("/api/v1/discovery/workloads", headers=bearer(ALICE))
        bob_resp = client.get("/api/v1/discovery/workloads", headers=bearer(BOB))
        assert alice_resp.status_code == 200, alice_resp.text
        assert bob_resp.status_code == 200, bob_resp.text
        assert TENANT_B not in alice_resp.text
        assert TENANT_A not in bob_resp.text
    finally:
        api_compat.reset_tenant_connectors(TENANT_A)
        api_compat.reset_tenant_connectors(TENANT_B)
