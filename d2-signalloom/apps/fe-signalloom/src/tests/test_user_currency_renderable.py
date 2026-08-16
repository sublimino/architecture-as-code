"""The display currency the API accepts must be one the dashboard can render.

WHY THIS FILE EXISTS, SEPARATELY FROM test_user_currency.py.

test_user_currency.py already asserts that a bad ``display_currency`` is
rejected, and it is a good test.  But look at what it drives::

    @pytest.mark.parametrize("bad", ["usd", "US", "USDD", "US$", "123", ""])
    def test_a_code_that_is_not_iso4217_is_rejected(...)
        \"\"\"Intl does not reject unknown currency codes -- it renders them.

        ``new Intl.NumberFormat('en-GB', {currency: 'ZZZ'}).format(1)`` returns
        the string "ZZZ 1.00" rather than throwing, so a bad code that reaches
        storage reaches the screen looking like a real money figure.  It has to
        be stopped here.\"\"\"

Every one of those six cases is a violation of SHAPE -- wrong case, wrong
length, non-alphabetic.  ``ZZZ``, the code the docstring names as the whole
reason the test exists, is not among them, and ``ZZZ`` is three uppercase
ASCII letters.  The validator checks ``value.isascii() and value.isalpha() and
value.isupper()``, so ``ZZZ`` passes, is persisted, and is written into the
audit trail as the user's chosen currency.

That is the shape of defect this repository keeps producing: two things that
must agree, with nothing checking that they do.  The two things here are the
set of codes the API will store and the set of codes
``dashboard-signalloom/src/money/currency.ts`` can render.  The API's set is
"any three uppercase letters" -- 17,576 codes.  The dashboard's set is fifteen.

The consequence is not a crash.  ``CurrencyContext.tsx`` line 99 reads the
stored preference through ``isCurrencyCode`` and silently falls back::

    setCurrencyState(isCurrencyCode(prefs.display_currency)
        ? prefs.display_currency
        : DEFAULT_CURRENCY)

So the user PATCHes ZZZ, gets a 200, the audit trail records
``user.currency_updated {from: USD, to: ZZZ}``, and the screen keeps showing
USD.  api_compat.py says exactly this, at the DEFAULT_DISPLAY_CURRENCY
constant, as the thing that must not happen::

    # If one of the four moves they all move, or a user sees one currency
    # while the audit trail records another.

A correct comment naming the failure, directly above code that permits it.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import api_compat

from test_user_currency import (  # noqa: F401  (client is a fixture)
    SUBJECT_TENANTS,
    _bearer,
    _currency_events,
    client,
)

# Give this module its own tenants: the in-memory stores are module-level and
# outlive a single test, so a shared subject would let one file's writes
# decide another file's assertions.
SUBJECT_TENANTS.setdefault("curr-renderable", "tenant-curr-renderable")
SUBJECT_TENANTS.setdefault("curr-unrenderable", "tenant-curr-unrenderable")


# The dashboard's vocabulary, read from the TypeScript rather than copied.
#
# Copying the list here would create a fourth place the same fifteen codes are
# written down, which is the defect this test exists to catch, one file over.
# Parsing the source means the test tracks the dashboard automatically: add a
# currency there and this test starts requiring the API to accept it.
#   .../apps/fe-signalloom/src/tests/this_file.py
#   parents[0]=tests  [1]=src  [2]=fe-signalloom  [3]=apps
_CURRENCY_TS = (
    Path(__file__).resolve().parents[3]
    / "dashboard-signalloom" / "src" / "money" / "currency.ts"
)


def _dashboard_supported_currencies() -> frozenset[str]:
    source = _CURRENCY_TS.read_text(encoding="utf-8")
    block = re.search(
        r"export const SUPPORTED_CURRENCIES[^=]*=\s*\[(?P<body>.*?)\]",
        source,
        re.DOTALL,
    )
    assert block is not None, (
        f"could not find SUPPORTED_CURRENCIES in {_CURRENCY_TS}. This test is only "
        f"meaningful while it reads the dashboard's real vocabulary -- a silent "
        f"fallback to a hardcoded list would make it pass for the wrong reason."
    )
    codes = frozenset(re.findall(r"'([A-Z]{3})'", block.group("body")))
    assert len(codes) >= 2, f"parsed only {codes!r} from SUPPORTED_CURRENCIES; the parse is broken"
    return codes


def test_the_dashboard_vocabulary_is_actually_readable() -> None:
    """Assert the mechanism before relying on it.

    Every test below is a claim about the dashboard's currency list. If the
    file moved or the regex stopped matching, those tests would degrade into
    assertions about an empty set and pass while checking nothing.
    """
    codes = _dashboard_supported_currencies()
    assert "USD" in codes and "GBP" in codes and "JPY" in codes, codes
    assert "ZZZ" not in codes, "ZZZ is the canonical unassigned code; it must not be offered"


@pytest.mark.parametrize("code", sorted(_dashboard_supported_currencies()))
def test_every_currency_the_dashboard_offers_is_accepted(client: TestClient, code: str) -> None:
    """The other half of the agreement, and the reason this is not just a tightening.

    A validator that rejected too much would be worse than one that rejects too
    little: a currency in the dropdown that the API refuses is a settings page
    that returns 422 on a legitimate choice.
    """
    response = client.patch(
        "/api/user/preferences",
        json={"display_currency": code},
        headers=_bearer("curr-renderable"),
    )
    assert response.status_code == 200, (
        f"{code} is offered by the dashboard's SUPPORTED_CURRENCIES but the API refused it: "
        f"{response.text}"
    )
    assert response.json()["display_currency"] == code


@pytest.mark.parametrize("code", ["ZZZ", "XYZ", "AAA", "QQQ", "XXX"])
def test_a_shape_valid_code_the_dashboard_cannot_render_is_rejected(
    client: TestClient, code: str,
) -> None:
    """Three uppercase letters is not the same claim as "a currency we can show".

    Observed before the fix: every one of these returned 200 and was persisted.
    ``XXX`` is worth calling out separately -- it is a real ISO 4217 assignment
    meaning "no currency", so a membership check against ISO alone would still
    admit it.  The binding constraint is the rate table and the dropdown, not
    the standard.
    """
    assert code not in _dashboard_supported_currencies(), (
        f"{code} is now offered by the dashboard, so it is no longer an example of "
        f"an unrenderable code -- this test needs a different one"
    )

    response = client.patch(
        "/api/user/preferences",
        json={"display_currency": code},
        headers=_bearer("curr-unrenderable"),
    )
    assert response.status_code == 422, (
        f"{code} was accepted with status {response.status_code}. The dashboard cannot render it, "
        f"so CurrencyContext falls back to USD while the audit trail records {code} -- a user "
        f"seeing one currency while the trail records another. Response: {response.text}"
    )


def test_a_rejected_code_reaches_neither_storage_nor_the_audit_trail(client: TestClient) -> None:
    """The consequence, asserted end to end rather than at the status code.

    A 422 that still wrote the audit row would leave the trail claiming a
    change that never happened, which is the same divergence pointing the other
    way.
    """
    tenant = SUBJECT_TENANTS["curr-unrenderable"]

    client.patch(
        "/api/user/preferences",
        json={"display_currency": "EUR"},
        headers=_bearer("curr-unrenderable"),
    )
    events_before = len(_currency_events(tenant))

    client.patch(
        "/api/user/preferences",
        json={"display_currency": "ZZZ"},
        headers=_bearer("curr-unrenderable"),
    )

    stored = client.get(
        "/api/user/preferences", headers=_bearer("curr-unrenderable"),
    ).json()["display_currency"]
    assert stored == "EUR", f"a refused change moved the stored value to {stored!r}"

    events_after = _currency_events(tenant)
    assert len(events_after) == events_before, (
        "a refused currency change wrote an audit event; the trail now records a change "
        f"the system did not make: {events_after[events_before:]!r}"
    )


def test_the_accepted_set_is_exactly_the_renderable_set(client: TestClient) -> None:
    """The seam itself, stated as one assertion over the whole alphabet slice.

    Sampling three-letter codes rather than all 17,576 keeps this fast while
    still covering the boundary: the sample deliberately includes codes that
    differ from a supported one by a single letter, which is what a typo
    actually looks like.
    """
    supported = _dashboard_supported_currencies()
    probes = sorted(supported) + [
        "USE", "GBQ", "EUS", "JPZ",  # one letter off a real one
        "ZZZ", "AAA", "XXX",         # unassigned or "no currency"
        "BTC", "XAU",                # real codes, but not in the rate table
    ]

    accepted: set[str] = set()
    for code in probes:
        response = client.patch(
            "/api/user/preferences",
            json={"display_currency": code},
            headers=_bearer("curr-unrenderable"),
        )
        if response.status_code == 200:
            accepted.add(code)

    over_accepted = accepted - supported
    under_accepted = supported - accepted
    assert not over_accepted, (
        f"the API stores {sorted(over_accepted)}, which the dashboard cannot render. Each one "
        f"is a user whose screen shows USD while the audit trail records their choice."
    )
    assert not under_accepted, (
        f"the dashboard offers {sorted(under_accepted)} but the API refuses them"
    )


def test_the_rejection_names_what_is_allowed() -> None:
    """An operator debugging a refused change must be able to act on the reason.

    Asserted against the MODEL, not the HTTP response, and deliberately so.
    ``install_api_exception_handlers`` maps every RequestValidationError to a
    flat ``{"code": "invalid_request", "message": "Request is invalid"}`` with
    the detail discarded, so no assertion about the wire body could ever see
    this text.  That is a considered choice -- an error that echoes caller input
    back is a reflection primitive, and one that enumerates the schema hands out
    a map -- so this test checks the message where it actually exists rather
    than arguing with the design.

    The consequence worth knowing: the actionable text reaches the server log
    and the developer running the model directly, never the API caller.
    """
    with pytest.raises(ValueError) as excinfo:
        api_compat.UserPreferencesPatchRequest(display_currency="ZZZ")

    message = str(excinfo.value)
    assert "ZZZ" in message, f"the error does not quote the offending code: {message}"
    assert "USD" in message and "GBP" in message, (
        f"the error does not say what IS accepted, so a developer cannot correct it: {message}"
    )


def test_the_python_and_typescript_lists_have_not_diverged() -> None:
    """api_compat's own constant must stay a subset of what the dashboard renders.

    DEFAULT_DISPLAY_CURRENCY is the value every user gets before they choose.
    If it ever left the dashboard's vocabulary, every new user would land on a
    preference their screen silently overrides -- the bug above, applied to
    everyone at once rather than to whoever typed a bad code.
    """
    assert api_compat.DEFAULT_DISPLAY_CURRENCY in _dashboard_supported_currencies(), (
        f"DEFAULT_DISPLAY_CURRENCY is {api_compat.DEFAULT_DISPLAY_CURRENCY!r}, which the dashboard "
        f"cannot render"
    )
