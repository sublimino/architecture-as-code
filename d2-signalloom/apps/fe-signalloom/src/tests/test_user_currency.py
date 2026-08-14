"""Per-user display currency contract for /api/user/preferences.

Every risk figure in the product is GBP at source and shown in the user's
chosen currency, defaulting to USD.  That makes the preference part of what a
number on screen MEANS, so these tests pin three things the display depends on:
the default, the per-user scoping, and the audit record.

The scoping test is the one that matters most.  A preference stored against the
tenant rather than the user would look identical in every single-user test and
would only reveal itself when a second person in the same bank changed their
own view and moved a colleague's board pack.
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

# The in-memory stores are module-level and outlive a single test, so anything
# asserting on a default needs a tenant nothing else has written to.
#
# "curr-alice" and "curr-bob" deliberately SHARE a tenant: they are the pair
# that proves the preference is per-user rather than per-tenant.
SUBJECT_TENANTS = {
    "curr-fresh": "tenant-curr-fresh",
    "curr-roundtrip": "tenant-curr-roundtrip",
    "curr-audit": "tenant-curr-audit",
    "curr-invalid": "tenant-curr-invalid",
    "curr-alice": "tenant-curr-shared",
    "curr-bob": "tenant-curr-shared",
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


def _currency_events(tenant_id: str) -> list[dict[str, Any]]:
    return [
        event
        for event in api_compat._AUDIT_EVENTS.get(tenant_id, [])
        if event["event_type"] == "user.currency_updated"
    ]


# ---------------------------------------------------------------------------
# The default
# ---------------------------------------------------------------------------

def test_a_user_who_has_never_chosen_gets_usd(client: TestClient) -> None:
    """The documented default, for a caller with no stored preference.

    Also the answer for a user with no user_preferences row at all, which is
    every user until the first time they change something: the column DEFAULT
    covers the pooled path and the ``or`` fallback in the handler covers the
    missing row.
    """
    response = client.get("/api/user/preferences", headers=_bearer("curr-fresh"))

    assert response.status_code == 200, response.text
    assert response.json() == {"display_currency": "USD"}


def test_the_default_matches_the_constant_the_frontend_and_migration_share(client: TestClient) -> None:
    # Four places say USD: this constant, the user_preferences column DEFAULT,
    # DEFAULT_CURRENCY in money/currency.ts and the demo fixture in fakeData.ts.
    # A user seeing one currency while the audit trail records another is the
    # failure this guards.
    assert api_compat.DEFAULT_DISPLAY_CURRENCY == "USD"
    response = client.get("/api/user/preferences", headers=_bearer("curr-fresh"))
    assert response.json()["display_currency"] == api_compat.DEFAULT_DISPLAY_CURRENCY


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

def test_patch_returns_the_saved_value(client: TestClient) -> None:
    response = client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-roundtrip"),
    )

    assert response.status_code == 200, response.text
    assert response.json() == {"display_currency": "EUR"}


def test_patch_then_get_round_trips_the_choice(client: TestClient) -> None:
    """A setting that does not survive the next page load is not a setting."""
    patched = client.patch(
        "/api/user/preferences",
        json={"display_currency": "GBP"},
        headers=_bearer("curr-roundtrip"),
    )
    assert patched.status_code == 200, patched.text

    fetched = client.get("/api/user/preferences", headers=_bearer("curr-roundtrip"))
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["display_currency"] == "GBP"


# ---------------------------------------------------------------------------
# Per-user scoping -- the point of the whole endpoint
# ---------------------------------------------------------------------------

def test_one_users_choice_does_not_move_another_users_figures(client: TestClient) -> None:
    """Two users, one tenant, independent preferences.

    Alice and Bob authenticate against the SAME tenant.  If the preference were
    stored per tenant -- as the scan preferences in tenant_settings correctly
    are -- Bob would silently inherit Alice's currency and every figure in his
    board pack would change denomination without him touching anything.
    """
    alice = client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-alice"),
    )
    assert alice.status_code == 200, alice.text

    bob = client.get("/api/user/preferences", headers=_bearer("curr-bob"))
    assert bob.status_code == 200, bob.text
    assert bob.json()["display_currency"] == "USD", (
        "Bob inherited Alice's currency -- the preference is tenant-scoped, not user-scoped"
    )

    # And Alice keeps hers.
    assert client.get(
        "/api/user/preferences", headers=_bearer("curr-alice"),
    ).json()["display_currency"] == "EUR"


def test_each_user_can_hold_a_different_currency_at_the_same_time(client: TestClient) -> None:
    client.patch("/api/user/preferences", json={"display_currency": "GBP"}, headers=_bearer("curr-alice"))
    client.patch("/api/user/preferences", json={"display_currency": "EUR"}, headers=_bearer("curr-bob"))

    assert client.get("/api/user/preferences", headers=_bearer("curr-alice")).json()["display_currency"] == "GBP"
    assert client.get("/api/user/preferences", headers=_bearer("curr-bob")).json()["display_currency"] == "EUR"


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------

def test_changing_the_currency_writes_an_audit_event(client: TestClient) -> None:
    """A settings change a regulated customer cannot see the history of is a gap."""
    before = len(_currency_events("tenant-curr-audit"))

    client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-audit"),
    )

    events = _currency_events("tenant-curr-audit")
    assert len(events) == before + 1


def test_the_audit_event_carries_the_old_and_new_values_and_the_actor(client: TestClient) -> None:
    """The trail has to answer who changed it, from what, to what.

    Recording only the new value would leave the previous one recoverable solely
    by replaying every earlier event, and recording no actor would make the row
    worthless as evidence.
    """
    client.patch(
        "/api/user/preferences",
        json={"display_currency": "GBP"},
        headers=_bearer("curr-audit"),
    )
    client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-audit"),
    )

    latest = _currency_events("tenant-curr-audit")[-1]
    assert latest["event_type"] == "user.currency_updated"
    assert latest["actor"] == "curr-audit"
    assert latest["detail"]["from"] == "GBP"
    assert latest["detail"]["to"] == "EUR"
    assert latest["detail"]["email"] == "curr-audit"


def test_the_first_change_records_the_default_as_the_previous_value(client: TestClient) -> None:
    # Not None and not absent: "it was the default" is a fact worth stating, and
    # a null previous value reads as "unknown" rather than "never set".
    client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-fresh"),
    )
    assert _currency_events("tenant-curr-fresh")[-1]["detail"]["from"] == "USD"


def test_the_event_type_is_user_scoped_not_tenant_scoped(client: TestClient) -> None:
    # tenant.preferences_updated already exists for tenant-wide scan settings.
    # Reusing it here would make a personal display choice indistinguishable
    # from a policy change affecting everyone.
    client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-audit"),
    )
    types = {event["event_type"] for event in api_compat._AUDIT_EVENTS.get("tenant-curr-audit", [])}
    assert "user.currency_updated" in types
    assert "tenant.preferences_updated" not in types


def test_the_event_type_fits_the_audit_column(client: TestClient) -> None:
    # audit_events.event_type is VARCHAR(30). An over-long type is a runtime
    # insert failure that rolls back the mutation it shares a transaction with.
    assert len("user.currency_updated") <= 30


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad", ["usd", "US", "USDD", "US$", "123", ""])
def test_a_code_that_is_not_iso4217_is_rejected(client: TestClient, bad: str) -> None:
    """Intl does not reject unknown currency codes -- it renders them.

    ``new Intl.NumberFormat('en-GB', {currency: 'ZZZ'}).format(1)`` returns the
    string "ZZZ 1.00" rather than throwing, so a bad code that reaches storage
    reaches the screen looking like a real money figure.  It has to be stopped
    here.
    """
    response = client.patch(
        "/api/user/preferences",
        json={"display_currency": bad},
        headers=_bearer("curr-invalid"),
    )
    assert response.status_code == 422, response.text


def test_a_rejected_change_leaves_the_stored_value_alone(client: TestClient) -> None:
    client.patch("/api/user/preferences", json={"display_currency": "EUR"}, headers=_bearer("curr-invalid"))
    client.patch("/api/user/preferences", json={"display_currency": "nope"}, headers=_bearer("curr-invalid"))

    assert client.get(
        "/api/user/preferences", headers=_bearer("curr-invalid"),
    ).json()["display_currency"] == "EUR"


def test_the_audited_email_comes_from_the_token_and_cannot_be_supplied(client: TestClient) -> None:
    """The actor on an audit row must be the authenticated caller, always.

    A client-supplied identity would let anyone write an audit row attributing
    a change to somebody else, which is worse than no audit row at all: it is
    evidence that actively misleads.  ``extra="forbid"`` on the request model
    means the attempt is rejected rather than ignored, so a client trying it
    finds out.
    """
    attempt = client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR", "email": "someone.else@bank.example"},
        headers=_bearer("curr-audit"),
    )
    assert attempt.status_code == 422, attempt.text

    # And a legitimate change records the principal, never a client value.
    client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-audit"),
    )
    latest = _currency_events("tenant-curr-audit")[-1]
    assert latest["detail"]["email"] == "curr-audit"
    assert latest["actor"] == "curr-audit"
    assert "someone.else@bank.example" not in str(latest)


def test_an_unknown_field_is_rejected_rather_than_silently_dropped(client: TestClient) -> None:
    response = client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR", "tenant_id": "somebody-elses-tenant"},
        headers=_bearer("curr-invalid"),
    )
    # extra="forbid": a client that thinks it can name a tenant here should be
    # told it cannot, not have the field quietly ignored.
    assert response.status_code == 422, response.text


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

def test_the_preference_cannot_be_read_without_a_token(client: TestClient) -> None:
    assert client.get("/api/user/preferences").status_code == 401


def test_the_preference_cannot_be_written_without_a_token(client: TestClient) -> None:
    response = client.patch("/api/user/preferences", json={"display_currency": "EUR"})
    assert response.status_code == 401
