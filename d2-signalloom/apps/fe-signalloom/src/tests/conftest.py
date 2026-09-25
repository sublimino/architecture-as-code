"""Suite-wide fixtures (introduced by EAPR-P2-1).

Two things live here, and only two:

1. ``EAPClient`` + ``eap_bearer`` — a *real-token* client for the EAP suites.
   The five EAP routers are mounted behind ``api_compat.authenticated_principal``
   (router-level ``dependencies=``), so a test that calls them must present a
   Dex-style JWT.  The client mints one per request through the same RSA/JWKS
   path the production verifier uses; nothing here bypasses or disables the
   dependency.  Modules opt in by declaring ``EAP_AUTHENTICATED = True`` at
   module scope, which turns on the JWT verifier settings for their tests.
   The default-deny suite deliberately uses the raw ``TestClient`` and no
   opt-in, so the guard it provides is never weakened by this file.

2. ``fresh_tenant_ownership`` — an explicit (not autouse) empty
   ``customer_hash -> tenant`` ownership map for tests that seed two tenants.

Nothing else is autouse.  In particular no fixture here sets ``DATABASE_URL``,
touches ``api_compat._get_pool`` or changes ``settings`` for modules that did
not opt in.
"""
from __future__ import annotations

import os
import time
from types import SimpleNamespace
from typing import Any

# Ensure test salt is present during pytest test collection / module imports
os.environ.setdefault("SIGNAL_LOOM_EAP_SALT", "test-eap-salt-2026")

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import eap_tenancy
from api_compat import settings

EAP_ISSUER = "https://issuer.test/dex"
EAP_AUDIENCE = "signalloom-api"
EAP_AZP = "signalloom-dashboard"
EAP_KEY_ID = "eap-test-key"

#: Two tenants.  Always two: a single-tenant fixture cannot detect a missing
#: tenant filter, because every row it can return is the caller's own.
EAP_ALICE, EAP_TENANT_A = "alice", "tenant-a"
EAP_BOB, EAP_TENANT_B = "bob", "tenant-b"
#: An operator: a tenant-a principal that is also on the superadmin subject
#: allow-list.  Process-wide reaper controls (reap-now, pause/resume, status,
#: metrics) are operator-only; alice and bob are plain tenants and get 403.
EAP_OPERATOR = "operator"
EAP_SUBJECT_TENANTS = {EAP_ALICE: EAP_TENANT_A, EAP_BOB: EAP_TENANT_B, EAP_OPERATOR: EAP_TENANT_A}
#: The process-wide reaper controls, the one place tenant binding is replaced by
#: the operator role.  Shared by the default-deny suite, the forged-header
#: suite and the sealed sweep so the three cannot disagree about the list.
EAP_OPERATOR_ONLY_ROUTES: frozenset[tuple[str, str]] = frozenset(
    {
        ("POST", "/api/v1/eap/lifecycle/reap-now"),
        ("POST", "/api/v1/eap/lifecycle/reaper/pause"),
        ("POST", "/api/v1/eap/lifecycle/reaper/resume"),
        ("GET", "/api/v1/eap/lifecycle/reaper/status"),
        ("GET", "/api/v1/eap/lifecycle/metrics"),
    }
)

_EAP_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _EapJwkClient:
    """Stands in for the JWKS endpoint: knows exactly one key, by ``kid``."""

    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        if jwt.get_unverified_header(token).get("kid") != EAP_KEY_ID:
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=_EAP_SIGNING_KEY.public_key())


def eap_token_for(subject: str = EAP_ALICE, *, lifetime: int = 300, extra_claims: dict[str, Any] | None = None) -> str:
    """An RS256 token the production verifier accepts, for ``subject``."""
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": EAP_ISSUER,
        "aud": EAP_AUDIENCE,
        "sub": subject,
        "iat": now,
        "nbf": now,
        "exp": now + lifetime,
        "azp": EAP_AZP,
    }
    if extra_claims:
        claims.update(extra_claims)
    return jwt.encode(claims, _EAP_SIGNING_KEY, algorithm="RS256", headers={"kid": EAP_KEY_ID, "typ": "JWT"})


def eap_bearer(subject: str = EAP_ALICE) -> dict[str, str]:
    """``Authorization`` header for ``subject`` (alice -> tenant-a, bob -> tenant-b)."""
    return {"Authorization": f"Bearer {eap_token_for(subject)}"}


def _has_authorization(headers: Any) -> bool:
    return any(str(k).lower() == "authorization" for k in (headers or {}))


class EAPClient(TestClient):
    """``TestClient`` that authenticates every request as ``subject``.

    A caller that sets ``Authorization`` itself (another tenant, a forged or
    empty token) wins; the client only fills the header in when it is absent.
    Websocket handshakes get the same treatment.
    """

    def __init__(self, app: Any, subject: str = EAP_ALICE, **kwargs: Any) -> None:
        super().__init__(app, **kwargs)
        self.subject = subject

    def _with_bearer(self, headers: Any) -> dict[str, str]:
        merged = dict(headers or {})
        if not _has_authorization(merged):
            merged.update(eap_bearer(self.subject))
        return merged

    def request(self, method: str, url: Any, *args: Any, headers: Any = None, **kwargs: Any) -> Any:  # type: ignore[override]
        return super().request(method, url, *args, headers=self._with_bearer(headers), **kwargs)

    def websocket_connect(self, url: str, subprotocols: Any = None, **kwargs: Any) -> Any:  # type: ignore[override]
        kwargs["headers"] = self._with_bearer(kwargs.get("headers"))
        return super().websocket_connect(url, subprotocols, **kwargs)


def configure_eap_jwt(monkeypatch: pytest.MonkeyPatch) -> None:
    """Point the production verifier at the test issuer and key.  Restored by monkeypatch."""
    monkeypatch.setattr(settings, "api_jwt_issuer", EAP_ISSUER)
    monkeypatch.setattr(settings, "api_jwt_audience", EAP_AUDIENCE)
    monkeypatch.setattr(settings, "api_jwt_authorized_party", EAP_AZP)
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(EAP_SUBJECT_TENANTS))
    monkeypatch.setattr(settings, "api_superadmin_subjects", {EAP_OPERATOR})
    monkeypatch.setattr(settings, "api_superadmin_emails", set())
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _EapJwkClient())


@pytest.fixture
def fresh_tenant_ownership(monkeypatch: pytest.MonkeyPatch) -> eap_tenancy.TenantOwnership:
    """An empty customer_hash -> tenant map for this test only.

    Not autouse on purpose: the EAP engines (environment registry, lifecycle
    manager, tenant boundaries, scenario manager) are module-level singletons
    that several suites read across tests, and an ownership map reset between
    tests would orphan the records those suites created a test earlier.  The
    map is therefore as long-lived as the engines it binds, and a test that
    needs two tenants over a clean slate asks for this fixture explicitly.
    """
    ownership = eap_tenancy.TenantOwnership()
    monkeypatch.setattr(eap_tenancy, "GLOBAL_TENANT_OWNERSHIP", ownership)
    return ownership


@pytest.fixture(autouse=True)
def _eap_jwt_env(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch):
    """JWT verifier settings for modules that declare ``EAP_AUTHENTICATED = True``."""
    if getattr(request.module, "EAP_AUTHENTICATED", False):
        configure_eap_jwt(monkeypatch)
    yield


@pytest.fixture
def eap_jwt_env(monkeypatch: pytest.MonkeyPatch):
    """Explicit form of the same settings, for tests in modules that did not opt in."""
    configure_eap_jwt(monkeypatch)
    yield


@pytest.fixture(autouse=True)
def _eap_test_salt(monkeypatch: pytest.MonkeyPatch):
    """Provide a default test salt in the environment for offline hermetic test runs."""
    import os
    if "SIGNAL_LOOM_EAP_SALT" not in os.environ:
        monkeypatch.setenv("SIGNAL_LOOM_EAP_SALT", "test-eap-salt-2026")
    yield

