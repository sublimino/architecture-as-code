"""Jurisdiction reporting on GET /api/compliance/frameworks.

READ-ONLY, and the tests say so: nothing is filtered, excluded or re-priced.
An out-of-jurisdiction regime is still returned with all its controls and
merely carries three reporting fields. Changing what is PRICED is a separate
decision from telling an operator what looks out of scope, and the second is
useful on its own.

The semantics are PORTED from ``Scenario.AppliesTo`` (model.go), not
reinvented, because a parallel concept would have meant two answers to "where
is this institution" and eventually two different answers. The two that are
easy to get backwards are pinned here explicitly:

  * omitted territories means GLOBAL (the permissive default every pack
    already had, so adding this axis moves nothing);
  * an institution that does not say where it is matches NO scoped regime --
    excluded rather than assumed, because silence must never read as a match.
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
from api_compat import (
    GLOBAL_TERRITORY,
    framework_applies_to,
    framework_jurisdiction_fields,
    framework_territories,
    settings,
)
from db.connection import set_pool_for_testing
from main import app

from tests.contract import FrameworkResponse

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

SUBJECT_TENANTS = {
    "juris-undeclared": "tenant-juris-undeclared",
    "juris-uk": "tenant-juris-uk",
    "juris-us": "tenant-juris-us",
    "juris-global": "tenant-juris-global",
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


def _bearer(subject: str) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now, "nbf": now, "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
        },
        TEST_SIGNING_KEY, algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external_network(*_a: Any, **_k: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


def _declare_jurisdiction(client: TestClient, subject: str, jurisdiction: str | None) -> None:
    response = client.patch(
        "/api/tenant/settings/risk-profile",
        json={"jurisdiction": jurisdiction},
        headers=_bearer(subject),
    )
    assert response.status_code == 200, response.text


# ---------------------------------------------------------------------------
# The ported predicate, in isolation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("territories", "jurisdiction", "expected"),
    [
        # Omitted territories means global: matches everything, including an
        # institution that has declared nothing.
        ((), "UK", True),
        ((), None, True),
        ((), "", True),
        # An explicit global marker is the same thing.
        ((GLOBAL_TERRITORY,), None, True),
        # Scoped, and the institution is in scope.
        (("UK",), "UK", True),
        (("UK", "DE", "FR"), "FR", True),
        # Scoped, and the institution is elsewhere.
        (("UK",), "US", False),
        # THE ONE THAT IS EASY TO GET BACKWARDS: silence matches nothing.
        (("UK",), None, False),
        (("UK",), "", False),
        (("UK",), "   ", False),
        # Case-insensitive and trimmed: 'uk' and 'UK' naming different things
        # would be a data trap, not a feature.
        (("UK",), "uk", True),
        (("UK",), " uk ", True),
        (("uk",), "UK", True),
        # The deliberate extension beyond the Go original: an institution that
        # declares it operates everywhere is in scope for every regime.
        (("UK",), GLOBAL_TERRITORY, True),
    ],
)
def test_the_ported_applies_to_semantics(
    territories: tuple[str, ...], jurisdiction: str | None, expected: bool,
) -> None:
    assert framework_applies_to(territories, jurisdiction) is expected


def test_an_unmapped_framework_is_global() -> None:
    """The permissive default, matching the engine's own.

    Scoping is an affirmative act by an author who knows the regime is not
    universal, so anything absent from the map applies everywhere -- which is
    the behaviour every framework had before this change.
    """
    assert framework_territories("cis-kubernetes") == ()
    assert framework_applies_to(framework_territories("cis-kubernetes"), None) is True
    assert framework_applies_to(framework_territories("totally-unknown-pack"), "US") is True


def test_a_mapped_framework_is_scoped() -> None:
    assert framework_territories("hipaa") == ("US",)
    assert framework_territories("HIPAA") == ("US",), "lookup must be case-insensitive"
    assert framework_applies_to(framework_territories("hipaa"), "US") is True
    assert framework_applies_to(framework_territories("hipaa"), "UK") is False


def test_an_exclusion_always_carries_its_reason() -> None:
    """An unexplained exclusion is indistinguishable from an oversight.

    Same argument as the mandatory ``provenance`` on a magnitude triple.
    """
    out_of_scope = framework_jurisdiction_fields("hipaa", "UK")
    assert out_of_scope["in_jurisdiction"] is False
    assert out_of_scope["out_of_jurisdiction_reason"]
    assert "US" in out_of_scope["out_of_jurisdiction_reason"]
    assert "UK" in out_of_scope["out_of_jurisdiction_reason"]

    in_scope = framework_jurisdiction_fields("hipaa", "US")
    assert in_scope["in_jurisdiction"] is True
    assert in_scope["out_of_jurisdiction_reason"] is None


def test_the_undeclared_reason_says_how_to_fix_it() -> None:
    fields = framework_jurisdiction_fields("hipaa", None)
    assert fields["in_jurisdiction"] is False
    reason = fields["out_of_jurisdiction_reason"]
    assert "not declared a jurisdiction" in reason
    assert "matches no scoped regime" in reason


# ---------------------------------------------------------------------------
# Through the endpoint
# ---------------------------------------------------------------------------

def test_an_undeclared_tenant_sees_every_framework_with_global_ones_in_scope(
    client: TestClient,
) -> None:
    response = client.get("/api/compliance/frameworks", headers=_bearer("juris-undeclared"))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body, "no frameworks, so this test would pass vacuously"
    for framework in body:
        FrameworkResponse.model_validate(framework)
        if not framework["territories"]:
            assert framework["in_jurisdiction"] is True, framework["id"]
            assert framework["out_of_jurisdiction_reason"] is None
        else:
            # Scoped regimes are out of scope for a tenant that said nothing.
            assert framework["in_jurisdiction"] is False, framework["id"]


def test_declaring_a_jurisdiction_brings_its_regimes_into_scope(client: TestClient) -> None:
    _declare_jurisdiction(client, "juris-us", "US")

    response = client.get("/api/compliance/frameworks", headers=_bearer("juris-us"))

    assert response.status_code == 200, response.text
    by_id = {f["id"]: f for f in response.json()}
    checked = False
    for fid, framework in by_id.items():
        territories = framework["territories"]
        if territories and "US" in territories:
            assert framework["in_jurisdiction"] is True, fid
            checked = True
        elif territories:
            assert framework["in_jurisdiction"] is False, fid
            checked = True
    assert checked, "no scoped framework in the fixture set, so this proved nothing"


def test_reporting_never_removes_a_framework_or_its_controls(client: TestClient) -> None:
    """The read-only guarantee, stated as a test.

    Out of jurisdiction must mean LABELLED, not dropped. Filtering would change
    what the compliance board counts, which is a pricing decision and not this
    one -- and a regime silently vanishing from the list is how an operator
    stops noticing an obligation they still have.
    """
    # NOT compared against a self-baseline. An earlier version of this test took
    # its "before" through the same endpoint and compared the two lists, which a
    # filter survives untouched: a filter applied to BOTH calls drops the same
    # regimes from both and the comparison still matches. Found by mutation, and
    # it is the reason this asserts a NAMED out-of-jurisdiction framework is
    # still present rather than that two lists agree.
    _declare_jurisdiction(client, "juris-uk", "UK")

    response = client.get("/api/compliance/frameworks", headers=_bearer("juris-uk"))
    assert response.status_code == 200, response.text
    by_id = {f["id"]: f for f in response.json()}

    # nist-800-53 is US-scoped, so it is out of jurisdiction for a UK tenant --
    # and it must still be here, in full, merely labelled.
    assert "nist-800-53" in by_id, (
        "a US-scoped framework vanished from a UK tenant's list; out of "
        f"jurisdiction must mean LABELLED, not dropped. Got: {sorted(by_id)}"
    )
    out_of_scope = by_id["nist-800-53"]
    assert out_of_scope["in_jurisdiction"] is False
    assert out_of_scope["out_of_jurisdiction_reason"]
    assert out_of_scope["control_count"] > 0, "controls were stripped"
    assert out_of_scope["controls"], "controls were stripped"

    # And an in-scope framework is present too, so the test is not merely
    # observing an endpoint that returns everything regardless.
    in_scope = [f for f in by_id.values() if f["in_jurisdiction"]]
    assert in_scope, "no framework is in scope, so this proved nothing"


def test_a_globally_operating_tenant_is_in_scope_everywhere(client: TestClient) -> None:
    _declare_jurisdiction(client, "juris-global", GLOBAL_TERRITORY)

    response = client.get("/api/compliance/frameworks", headers=_bearer("juris-global"))

    assert response.status_code == 200, response.text
    for framework in response.json():
        assert framework["in_jurisdiction"] is True, framework["id"]
        assert framework["out_of_jurisdiction_reason"] is None
