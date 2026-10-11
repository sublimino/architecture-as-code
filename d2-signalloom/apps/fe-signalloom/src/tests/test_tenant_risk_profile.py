"""Contract for PATCH /api/tenant/settings/risk-profile.

The onboarding wizard's identity step collected an organisation profile and
threw it away: ``TenantIdentityStep`` gathered five fields,
``OnboardingWizard`` held them in React state, and nothing ever PATCHed them
anywhere -- they did not even land in ``wizard_state``.  This route is where
the declared half of the risk model now lands.

Two storage paths are pinned, matching ``test_tenant_preferences.py``: the
in-memory fixture store (no Postgres pool) and the request/response contract.

THE INVARIANT THAT MATTERS MOST here is the one about silence.  A tenant that
declines to declare must read back as all-NULL, because the engine's fallback
to its own constants is what keeps every existing money figure where it is.
If an undeclared tenant ever acquires a default reporting currency or risk
load, every priced figure in the product moves for tenants who never asked for
it.  ``test_a_fresh_tenant_declares_nothing`` is that guard.
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

from tests.contract import TenantSettingsResponse

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# Each subject maps to its own tenant: the in-memory stores are module-level
# and persist for the whole process, so tests that assert on the undeclared
# state need a tenant no other test has written to.
SUBJECT_TENANTS = {
    "risk-fresh": "tenant-risk-fresh",
    "risk-roundtrip": "tenant-risk-roundtrip",
    "risk-partial": "tenant-risk-partial",
    "risk-invalid": "tenant-risk-invalid",
    "risk-normalise": "tenant-risk-normalise",
}

A_FULL_PROFILE = {
    "sector": "healthcare-provider",
    "jurisdiction": "US",
    "reporting_currency": "USD",
    "risk_appetite_tolerance": 6000.0,
    "risk_load": 0.25,
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
# Silence stays silence
# ---------------------------------------------------------------------------

def test_a_fresh_tenant_declares_nothing(client: TestClient) -> None:
    """No declared profile reads back as all-NULL, never as a default posture.

    This is the storage-layer half of "no existing figure moves unless a
    tenant opts in".  A default reporting currency or risk load here would be
    a posture the tenant never stated, and the engine would price with it.
    """
    response = client.get("/api/tenant/settings", headers=_bearer("risk-fresh"))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["sector"] is None
    assert body["jurisdiction"] is None
    assert body["reporting_currency"] is None
    assert body["risk_appetite_tolerance"] is None
    assert body["risk_load"] is None
    TenantSettingsResponse.model_validate(body)


# ---------------------------------------------------------------------------
# The happy path
# ---------------------------------------------------------------------------

def test_patch_risk_profile_is_routed_and_returns_the_declared_values(
    client: TestClient,
) -> None:
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json=A_FULL_PROFILE,
        headers=_bearer("risk-roundtrip"),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["sector"] == "healthcare-provider"
    assert body["jurisdiction"] == "US"
    assert body["reporting_currency"] == "USD"
    assert body["risk_appetite_tolerance"] == 6000.0
    assert body["risk_load"] == 0.25


def test_patch_risk_profile_response_validates_against_the_consumer_contract(
    client: TestClient,
) -> None:
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json=A_FULL_PROFILE,
        headers=_bearer("risk-roundtrip"),
    )

    assert response.status_code == 200, response.text
    # extra="forbid" on both sides, so this fails if either model drifts.
    model = TenantSettingsResponse.model_validate(response.json())
    assert model.sector == "healthcare-provider"
    assert model.reporting_currency == "USD"
    assert model.risk_load == 0.25


def test_patch_then_get_round_trips_the_declared_profile(client: TestClient) -> None:
    patched = client.patch(
        "/api/tenant/settings/risk-profile",
        json=A_FULL_PROFILE,
        headers=_bearer("risk-roundtrip"),
    )
    assert patched.status_code == 200, patched.text

    fetched = client.get("/api/tenant/settings", headers=_bearer("risk-roundtrip"))

    assert fetched.status_code == 200, fetched.text
    body = fetched.json()
    for key, value in A_FULL_PROFILE.items():
        assert body[key] == value, key


# ---------------------------------------------------------------------------
# Skippable, and a whole-profile declaration rather than a partial merge
# ---------------------------------------------------------------------------

def test_an_empty_declaration_is_accepted_and_clears_nothing_into_defaults(
    client: TestClient,
) -> None:
    """The wizard step is skippable, so an empty body must be valid."""
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={},
        headers=_bearer("risk-partial"),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["sector"] is None
    assert body["reporting_currency"] is None
    assert body["risk_load"] is None


def test_the_route_replaces_the_whole_profile_rather_than_merging(
    client: TestClient,
) -> None:
    """An omitted field means UNDECLARED, not "leave what was there".

    Stated as a test because the alternative -- a partial merge -- cannot
    express "I no longer wish to declare a jurisdiction", and a route that
    silently keeps a stale declaration is how a tenant ends up priced against
    a posture it thinks it withdrew.  Same whole-value semantics as the
    sibling preferences route.
    """
    first = client.patch(
        "/api/tenant/settings/risk-profile",
        json=A_FULL_PROFILE,
        headers=_bearer("risk-partial"),
    )
    assert first.status_code == 200, first.text
    assert first.json()["jurisdiction"] == "US"

    second = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"sector": "retail-ecommerce"},
        headers=_bearer("risk-partial"),
    )

    assert second.status_code == 200, second.text
    body = second.json()
    assert body["sector"] == "retail-ecommerce"
    assert body["jurisdiction"] is None
    assert body["reporting_currency"] is None
    assert body["risk_appetite_tolerance"] is None
    assert body["risk_load"] is None


@pytest.mark.parametrize("blank", ["", "   "])
def test_blank_strings_are_normalised_to_undeclared(
    client: TestClient, blank: str,
) -> None:
    """A skipped text input arrives as '' and must not be stored as declared.

    A whitespace-only jurisdiction trims to empty, which ``Scenario.AppliesTo``
    treats as "no jurisdiction stated" -- so storing it would behave as NULL
    while reading as declared in the UI.
    """
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"sector": blank, "jurisdiction": blank},
        headers=_bearer("risk-normalise"),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["sector"] is None
    assert body["jurisdiction"] is None


@pytest.mark.parametrize(
    ("sent", "stored"),
    [("us", "US"), (" us ", "US"), ("Uk", "UK"), ("*", "*")],
)
def test_jurisdiction_is_normalised_to_canonical_form(
    client: TestClient, sent: str, stored: str,
) -> None:
    """``AppliesTo`` is case-insensitive, so 'uk' and 'UK' must not both exist.

    Normalising on the way in is what lets the column carry a canonical-form
    CHECK; without it a valid-looking payload would be rejected by the database
    rather than by the handler that could explain it.
    """
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"jurisdiction": sent},
        headers=_bearer("risk-normalise"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["jurisdiction"] == stored


# ---------------------------------------------------------------------------
# Rejection, loudly
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("currency", ["ZZZ", "XXX", "XAU", "gbp", "GB", "GBPP", "G8P"])
def test_an_unpriceable_currency_is_rejected_rather_than_stored(
    client: TestClient, currency: str,
) -> None:
    """The binding constraint is the FX rate table, not ISO 4217 membership.

    ``XXX`` is a real ISO assignment meaning "no currency" and ``XAU`` is gold;
    both are valid codes and neither is something this product can price.  And
    the failure mode is not a crash: ``Intl.NumberFormat`` RENDERS an
    unrecognised code instead of throwing, so an accepted-but-unpriceable code
    arrives on screen looking like real money while every figure silently falls
    back to the default currency.
    """
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"reporting_currency": currency},
        headers=_bearer("risk-invalid"),
    )

    assert response.status_code == 422, response.text


@pytest.mark.parametrize("currency", ["USD", "GBP", "EUR", "JPY"])
def test_a_priceable_currency_is_accepted(client: TestClient, currency: str) -> None:
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"reporting_currency": currency},
        headers=_bearer("risk-normalise"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["reporting_currency"] == currency


@pytest.mark.parametrize("risk_load", [-0.01, -1.0])
def test_a_negative_risk_load_is_rejected(
    client: TestClient, risk_load: float,
) -> None:
    """A negative load would make carried risk less than tail risk."""
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"risk_load": risk_load},
        headers=_bearer("risk-invalid"),
    )

    assert response.status_code == 422, response.text


def test_a_zero_risk_load_is_accepted(client: TestClient) -> None:
    """Zero is a coherent posture: carry the tail with no load on top."""
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"risk_load": 0},
        headers=_bearer("risk-normalise"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["risk_load"] == 0.0


@pytest.mark.parametrize("raw", ["NaN", "Infinity", "-Infinity"])
def test_a_non_finite_risk_load_is_rejected(client: TestClient, raw: str) -> None:
    """JSON has no NaN, but Python's decoder accepts the literal.

    So a client CAN send one, and if it lands it propagates through
    ``tvar * (1 + risk_load)`` to produce a carried figure that passes every
    structural check and is not a number.  Rejected at the handler as well as
    by the column CHECK, because the handler can say why.
    """
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        content=f'{{"risk_load": {raw}}}',
        headers={**_bearer("risk-invalid"), "Content-Type": "application/json"},
    )

    assert response.status_code == 422, response.text


@pytest.mark.parametrize("tolerance", [0, -1, -0.5])
def test_a_non_positive_appetite_tolerance_is_rejected(
    client: TestClient, tolerance: float,
) -> None:
    """Without a tolerance band a number cannot become a verdict."""
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"risk_appetite_tolerance": tolerance},
        headers=_bearer("risk-invalid"),
    )

    assert response.status_code == 422, response.text


@pytest.mark.parametrize("raw", ["NaN", "Infinity"])
def test_a_non_finite_appetite_tolerance_is_rejected(
    client: TestClient, raw: str,
) -> None:
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        content=f'{{"risk_appetite_tolerance": {raw}}}',
        headers={**_bearer("risk-invalid"), "Content-Type": "application/json"},
    )

    assert response.status_code == 422, response.text


def test_an_unknown_field_is_rejected(client: TestClient) -> None:
    """extra="forbid": a typo'd field must not be silently dropped."""
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"risk_loadd": 0.2},
        headers=_bearer("risk-invalid"),
    )

    assert response.status_code == 422, response.text


def test_the_route_requires_authentication(client: TestClient) -> None:
    response = client.patch("/api/tenant/settings/risk-profile", json=A_FULL_PROFILE)

    assert response.status_code == 401, response.text
