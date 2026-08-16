"""The audit vocabulary the dashboard offers must match the one the API emits.

``test_audit_event_types.py`` closes the seam between the event types
``_audit_log()`` writes and the CHECK constraint that permits them. It stops the
database rejecting a write. It says nothing about whether an operator can ever
*see* that write, and that is a second seam with the same shape and nothing
checking it.

``views/AuditTrail.tsx`` renders a filter ``<select>`` from a hand-maintained
``EVENT_TYPES`` array and colours each row from a hand-maintained
``EVENT_COLORS`` map. Both were written against migration 007's undotted
vocabulary. ``_audit_log()`` has since moved to a dotted convention and grown to
22 types. Measured at the commit this guard was written:

* 21 of the 22 event types the API actually emits had **no filter option** —
  including every credential issue and revoke, every API-key rotation, every
  consent acceptance, and every tenant framework change.
* 10 of the 11 filter options on offer matched **nothing the API emits**. An
  operator selecting "violation_detected" got an empty table and no indication
  that the filter was dead rather than the period being quiet.

That is the failure mode this repository keeps re-encountering: two things that
must agree, with nothing checking that they do. It failed silently in the most
expensive place available — the audit trail is the evidence surface of a product
sold on regulatory evidence, and it was quietly unsearchable for the events that
matter most.

The drift was known. ``AuditTrail.tsx`` carried a comment saying so ("Closing
the rest of the drift is a separate change"), which is precisely why a comment
is not a guard: it documented the defect and then let it persist across every
subsequent commit. A correct comment guarding incorrect code reads as a decision
rather than a bug, so nobody reopens it.

So this file derives both sides and restates neither:

* the emitted side comes from ``test_audit_event_types._extract_event_types()``
  — the same AST walk that already resolves literals and one-hop parameters, and
  that *fails* rather than under-reporting when a call site cannot be resolved.
  Importing it, rather than re-implementing it, means a third emitter module
  cannot be added without both guards following it.
* the dashboard side is parsed out of the TSX source.

Adding an event type to the API now fails here until the dashboard can display
and filter it.
"""
from __future__ import annotations

import re
from pathlib import Path

from test_audit_event_types import (
    _extract_event_types,
    _permitted_event_types,
)

DASHBOARD_SRC = (
    Path(__file__).resolve().parents[3] / "dashboard-signalloom" / "src"
)
AUDIT_TRAIL = DASHBOARD_SRC / "views" / "AuditTrail.tsx"
AGENT_DETAIL = DASHBOARD_SRC / "pages" / "AgentDetailPage.tsx"


# Event types permitted by the constraint that no call site emits, kept as
# filter options on purpose. Migration 007 created them and long-lived
# environments may hold rows using them, so an operator auditing historical data
# still needs to select them. They are named here rather than exempted by a
# pattern rule, because "undotted means legacy" is a convention the next
# migration is free to break.
#
# An entry here must still be permitted by the CHECK constraint. Once a
# migration drops one, the filter option can only ever match zero rows, and
# `test_no_stale_legacy_filter_options` fails so the entry is removed rather
# than left to rot.
LEGACY_FILTER_ONLY_EVENT_TYPES = {
    "enrollment",
    "state_transition",
    "violation_detected",
    "compliance_check",
    "token_issued",
    "token_refused",
    "tenant_created",
    "user_provisioned",
    "directory_connected",
    "discovery_enroll_requested",
}


def _array_literal(source: Path, name: str) -> list[str]:
    """The string entries of ``const <name> = [ ... ]`` in a TSX file.

    Deliberately narrow. A TSX parser is a second system to trust, and the
    thing being read is a flat array of string literals — but "narrow" must not
    mean "silently empty", so every caller asserts a non-zero result. A regex
    that stops matching after a refactor would otherwise turn this whole file
    into decoration that reports success.
    """
    text = source.read_text()
    match = re.search(rf"const\s+{name}\s*(?::[^=]+)?=\s*\[(.*?)\]", text, re.S)
    assert match is not None, (
        f"no `const {name} = [...]` found in {source.name}. The guard cannot "
        "read the dashboard's vocabulary, so it must fail rather than report "
        "that the vocabulary agrees."
    )
    body = re.sub(r"//[^\n]*", "", match.group(1))
    return re.findall(r"['\"]([^'\"]+)['\"]", body)


def _record_keys(source: Path, name: str) -> set[str]:
    """The keys of ``const <name>: Record<string, string> = { ... }``.

    Keys are quoted when they contain a dot and bare otherwise, so both forms
    are read. Comments are stripped first: ``EVENT_COLORS`` carries prose
    mentioning event names, and counting those as declared colours would let a
    genuinely uncoloured type pass.
    """
    text = source.read_text()
    match = re.search(rf"const\s+{name}\s*(?::[^=]+)?=\s*\{{(.*?)\n\}}", text, re.S)
    assert match is not None, f"no `const {name} = {{...}}` found in {source.name}"
    body = re.sub(r"//[^\n]*", "", match.group(1))
    return set(re.findall(r"^\s*['\"]?([A-Za-z][\w.]*)['\"]?\s*:", body, re.M))


def _emitted() -> set[str]:
    resolved, unresolved = _extract_event_types()
    assert not unresolved, (
        f"{len(unresolved)} _audit_log call site(s) whose event type could not "
        f"be resolved: {unresolved}. An extractor that under-reports makes this "
        "guard read as coverage while providing none."
    )
    return resolved


# ── mechanism checks ────────────────────────────────────────────────────
#
# Each side of the comparison is extracted by a reader that can silently return
# nothing. A guard whose extractors both return the empty set agrees with
# itself perfectly and tests the product not at all — the exact defect that let
# `make -C d2-signalloom test` report success over 22 suites it never ran.


def test_the_dashboard_declares_filter_options_at_all() -> None:
    assert len(_array_literal(AUDIT_TRAIL, "EVENT_TYPES")) >= 5


def test_the_dashboard_declares_colours_at_all() -> None:
    assert len(_record_keys(AUDIT_TRAIL, "EVENT_COLORS")) >= 5


def test_the_api_emits_event_types_at_all() -> None:
    assert len(_emitted()) >= 10


# ── the seam ────────────────────────────────────────────────────────────


def test_every_emitted_event_type_is_filterable() -> None:
    """The bug, stated as an assertion.

    An event the API writes but the dashboard cannot filter is an audit record
    that exists in the database and is unreachable from the product. On the
    audit trail specifically, that is indistinguishable to an operator from the
    event never having happened.
    """
    offered = set(_array_literal(AUDIT_TRAIL, "EVENT_TYPES"))
    missing = sorted(_emitted() - offered)
    assert not missing, (
        f"{len(missing)} event type(s) the API emits have no filter option in "
        f"AuditTrail.tsx: {missing}. Each is written to audit_events and cannot "
        "be isolated by an operator. Add them to EVENT_TYPES and EVENT_COLORS."
    )


def test_every_filter_option_matches_something_the_api_emits() -> None:
    """The other direction: a filter that can only ever return zero rows.

    A dead filter is worse than a missing one. An operator who selects it sees
    an empty table and concludes no such events occurred, when in truth no such
    events were ever *possible*. That is a false negative on an evidence
    surface, and it is silent by construction.
    """
    offered = set(_array_literal(AUDIT_TRAIL, "EVENT_TYPES"))
    dead = sorted(offered - _emitted() - LEGACY_FILTER_ONLY_EVENT_TYPES)
    assert not dead, (
        f"{len(dead)} filter option(s) in AuditTrail.tsx match no event type the "
        f"API emits: {dead}. Either the emitter was removed and the option "
        "should go with it, or the option is intentional historical vocabulary "
        "and belongs in LEGACY_FILTER_ONLY_EVENT_TYPES with a reason."
    )


def test_no_stale_legacy_filter_options() -> None:
    """An allowlist entry whose target no longer exists is itself a defect.

    Allowlists rot in one direction: entries get added and never removed. If a
    migration drops one of these from the CHECK constraint, no row can hold it,
    the filter option is permanently dead, and without this test the exemption
    would keep it looking deliberate forever.
    """
    permitted = _permitted_event_types()
    assert len(permitted) >= 10, "constraint parser returned almost nothing"
    stale = sorted(LEGACY_FILTER_ONLY_EVENT_TYPES - permitted)
    assert not stale, (
        f"{len(stale)} entry(ies) in LEGACY_FILTER_ONLY_EVENT_TYPES are no "
        f"longer permitted by the audit_events CHECK constraint: {stale}. No "
        "row can hold these values, so the filter options are dead. Remove them "
        "from both the allowlist and AuditTrail.tsx."
    )


def test_every_filter_option_has_a_colour() -> None:
    """A type in EVENT_TYPES but not EVENT_COLORS renders grey.

    Called out in AuditTrail.tsx's own comment as a thing you must remember to
    do by hand, which is the definition of a seam worth checking mechanically.
    """
    offered = set(_array_literal(AUDIT_TRAIL, "EVENT_TYPES"))
    uncoloured = sorted(offered - _record_keys(AUDIT_TRAIL, "EVENT_COLORS"))
    assert not uncoloured, (
        f"{len(uncoloured)} filter option(s) have no EVENT_COLORS entry and "
        f"render grey: {uncoloured}."
    )


def test_agent_detail_timeline_filters_match_emitted_types() -> None:
    """The same array, duplicated on a second page, drifted further.

    AgentDetailPage.tsx filters an agent's own timeline. It carries its own
    copy of the vocabulary, so it drifted independently and further: it offers
    only undotted legacy values, meaning the per-agent timeline cannot filter to
    a single event the platform emits about that agent -- not its creation, not
    its transitions, not its credential issue or revoke, not its stun.
    """
    offered = set(_array_literal(AGENT_DETAIL, "EVENT_TYPES"))
    assert offered, "AgentDetailPage.tsx declares no EVENT_TYPES"
    dead = sorted(offered - _emitted() - LEGACY_FILTER_ONLY_EVENT_TYPES)
    assert not dead, (
        f"{len(dead)} timeline filter option(s) in AgentDetailPage.tsx match no "
        f"emitted event type: {dead}."
    )
    agent_scoped = {t for t in _emitted() if t.startswith("agent.")}
    missing = sorted(agent_scoped - offered)
    assert not missing, (
        f"{len(missing)} agent-scoped event type(s) the API emits cannot be "
        f"filtered on the agent's own timeline: {missing}. These are the events "
        "the per-agent audit view exists to show."
    )
