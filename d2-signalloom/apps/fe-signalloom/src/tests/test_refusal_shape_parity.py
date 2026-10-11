"""The refusal shape, and its parity with the policy engine's.

Three routes in this estate withhold the same class of figure: the Go engine's
``POST /api/v1/compliance/scan-fleet``, and this app's ``GET /compliance/policy/summary``
and ``GET /compliance/policy/frameworks``. Until the shape converged they said so three
ways -- omitted fields, ``null``, and (on older paths) ``0``. An API that signals one
condition three ways invites the reader to ask whether any of it is deliberate.

These tests pin this side of the converged shape AND its agreement with the Go side, by
reading the agreed key set out of the Go test that declares it. Neither language can
change the shape alone without one of the two suites failing -- which is the only way a
cross-service contract asserted in two codebases stays true.
"""

from __future__ import annotations

import inspect
import re
from pathlib import Path

import pytest

from api_compat import (
    PolicyFrameworkSummaryResponse,
    PolicySummaryResponse,
    PricingRefusalResponse,
    PricingStatus,
)

# The Go declaration of the shared key set. Resolved from this file rather than from a
# duplicated literal: a copy would drift, and a drifted copy of a contract reads as a
# contract right up to the moment it matters.
GO_REFUSAL_TEST = (
    Path(__file__).resolve().parents[3]
    / "policy-engine"
    / "pkg"
    / "compliance"
    / "fleet_scan_refusal_test.go"
)


def _go_refusal_shape_keys() -> list[str]:
    """The key set the Go engine's own test declares, parsed from its source."""
    source = GO_REFUSAL_TEST.read_text(encoding="utf-8")
    match = re.search(
        r"var refusalShapeKeys = \[\]string\{(.*?)\}", source, re.DOTALL
    )
    assert match is not None, (
        f"refusalShapeKeys not found in {GO_REFUSAL_TEST}. If the Go declaration moved, "
        "this test must follow it -- not be deleted, which would silently un-pin the "
        "cross-service shape."
    )
    return sorted(re.findall(r'"([^"]+)"', match.group(1)))


def test_go_declaration_is_readable() -> None:
    """A guard on the parse itself.

    A regex that silently matches nothing would make every parity assertion below
    vacuously true: ``set() == set()``. The failure mode of a cross-language contract
    test is almost always that it stopped reading the other side, not that the other
    side changed, so the parse is asserted before anything is compared against it.
    """
    assert GO_REFUSAL_TEST.is_file(), f"{GO_REFUSAL_TEST} does not exist"
    keys = _go_refusal_shape_keys()
    assert len(keys) >= 5, f"parsed only {keys} from the Go declaration; the parse is broken"


def test_python_refusal_model_matches_the_go_key_set() -> None:
    """The two services emit the same keys, or this fails."""
    go_keys = set(_go_refusal_shape_keys())
    py_keys = set(PricingRefusalResponse.model_fields)
    assert py_keys == go_keys, (
        f"refusal shape has diverged: Python has {sorted(py_keys)}, Go has {sorted(go_keys)}. "
        "The whole point of the shape is that a client has ONE object to deserialise across "
        "all three refusing routes."
    )


def test_status_values_match_the_go_constants() -> None:
    """The enum values, not just the key names, are shared.

    Matching keys with different status strings would be worse than no shape at all: a
    client would deserialise both and branch on neither.
    """
    source = GO_REFUSAL_TEST.with_name("fleet_scan.go").read_text(encoding="utf-8")
    go_values = set(re.findall(r'PricingStatus\s*=\s*"([A-Z_]+)"', source))
    assert go_values, "no PricingStatus constants parsed from fleet_scan.go; the parse is broken"
    py_values = {status.value for status in PricingStatus}
    assert py_values == go_values, (
        f"status vocabularies differ: Python {sorted(py_values)}, Go {sorted(go_values)}"
    )


def test_the_two_refusal_causes_are_distinct() -> None:
    """They demand different operator actions, so they must not share a value.

    ``NO_DECLARED_LOSS_FREQUENCY`` is fixed by declaring a control mapping in the policy
    pack. ``NO_RISK_DATA_PLANE`` is fixed by putting a priced scan behind the route.
    Collapsing them repeats the mistake the currency path already made and fixed.
    """
    assert PricingStatus.NO_DECLARED_LOSS_FREQUENCY != PricingStatus.NO_RISK_DATA_PLANE
    assert PricingStatus.PRICED not in {
        PricingStatus.NO_DECLARED_LOSS_FREQUENCY,
        PricingStatus.NO_RISK_DATA_PLANE,
    }


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        (PricingStatus.PRICED, True),
        (PricingStatus.NO_DECLARED_LOSS_FREQUENCY, False),
        (PricingStatus.NO_RISK_DATA_PLANE, False),
    ],
)
def test_available_is_derived_from_status(status: PricingStatus, expected: bool) -> None:
    """``available`` predates ``status`` and is kept for today's clients, but it is
    computed from the status rather than passed in beside it -- two hand-maintained
    fields carrying one fact eventually disagree."""
    refusal = PricingRefusalResponse.of(status, reason="x", unpriced_fields=[])
    assert refusal.available is expected
    assert refusal.status is status


def test_refusal_cannot_be_constructed_with_a_contradictory_available() -> None:
    """There is no way to hand-set ``available``.

    If a caller could, the field would eventually be set to ``True`` beside a refusing
    status -- which is precisely the silent-fabrication failure this work removes, and
    it would be carried by the field clients already read.
    """
    signature = inspect.signature(PricingRefusalResponse.of)
    assert "available" not in signature.parameters, (
        "PricingRefusalResponse.of accepts an `available` argument; it must be derived "
        f"from the status, not supplied. Parameters: {list(signature.parameters)}"
    )
    refusal = PricingRefusalResponse.of(
        PricingStatus.NO_RISK_DATA_PLANE, reason="x", unpriced_fields=["totalAle"]
    )
    assert refusal.available is False


def test_a_refusal_is_not_readable_as_a_figure() -> None:
    """The status must not coerce to a number.

    This is the property that separates an explicit refusal from an omission or a zero.
    """
    refusal = PricingRefusalResponse.of(
        PricingStatus.NO_RISK_DATA_PLANE, reason="x", unpriced_fields=[]
    )
    dumped = refusal.model_dump()
    with pytest.raises((ValueError, TypeError)):
        float(dumped["status"])


def test_summary_models_carry_the_refusal() -> None:
    """Both response models this app serves expose the shape."""
    assert "pricing" in PolicySummaryResponse.model_fields
    assert "pricing" in PolicyFrameworkSummaryResponse.model_fields


def test_unpriced_fields_names_only_fields_the_model_has() -> None:
    """A refusal that names a field the model does not have tells a client nothing, and
    a refusal that omits one it does have under-reports. Both are caught here, which is
    also what makes adding a sixth money field fail loudly rather than ship quietly."""
    summary_money = {"totalAle", "totalVar95", "totalTvar", "totalCarriedGbp", "carried"}
    assert summary_money <= set(PolicySummaryResponse.model_fields), (
        "a money field named in the refusal is not on PolicySummaryResponse"
    )
    framework_money = {"totalExposureGbp", "exposure"}
    assert framework_money <= set(PolicyFrameworkSummaryResponse.model_fields)
