"""Lifecycle states: what the API writes, what the DB permits, what the UI offers.

Three artefacts have to agree about the same vocabulary and only one pair of
them has ever been checked.

Migration 009 exists because two of them disagreed: ``agent_registry`` permitted
``enrolled | active | suspended | revoked`` while the create path hardcodes
``'registered'`` in its INSERT, so *every agent create against a real database*
raised CheckViolationError. It was invisible until the tier-2 integration suite
first ran, because the tier-1 fixture store is a dict and a dict enforces no
constraints. 009 widened the constraint and left no guard behind, so the same
drift can reappear the moment a new state is written.

The third artefact was never checked at all. ``AgentsPage.tsx`` filters the
fleet from a hand-maintained ``LIFECYCLE_OPTIONS`` array, and
``AgentDetailPage.tsx`` offers transition targets from its own hand-maintained
table. Measured when this guard was written, ``LIFECYCLE_OPTIONS`` omitted
``registered`` — the state the INSERT hardcodes, which means **every agent the
product creates lands in a state the fleet view cannot filter to**. An operator
looking for newly-registered agents had no way to ask for them.

The two directions fail differently and both fail quietly:

* a state the API writes but the UI cannot filter — agents exist and are
  unreachable through the control the page provides for reaching them;
* a state the UI offers as a *transition target* that the constraint forbids —
  the write raises CheckViolationError and the endpoint 500s, but only when
  somebody presses that particular button.

So each side is derived. The permitted set is parsed from the migration SQL, the
written set from the source of the statements that write it, and the offered
sets from the TSX. The TSX readers are imported from
``test_dashboard_audit_vocabulary`` rather than copied — a second copy of an
extractor is a second thing to keep in step, which is the defect class this file
belongs to.

**A boundary this cannot close, stated rather than hidden:** ``POST
/agents/{id}/transition`` types ``to_state`` as a bare ``str`` with no Literal,
enum, or validator, so a caller may send any string and the CHECK constraint is
the only thing standing between that and the table. This file cannot enumerate
what an arbitrary caller will send; it can only hold the *dashboard's* offered
targets to the permitted set. Constraining ``to_state`` at the API boundary is a
change to the product, not to its tests, and is left named here so it is not
mistaken for covered ground.
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

from test_dashboard_audit_vocabulary import (
    DASHBOARD_SRC,
    _array_literal,
)

SRC_DIR = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = SRC_DIR / "db" / "migrations"
API_COMPAT = SRC_DIR / "api_compat.py"

AGENTS_PAGE = DASHBOARD_SRC / "pages" / "AgentsPage.tsx"
AGENT_DETAIL = DASHBOARD_SRC / "pages" / "AgentDetailPage.tsx"

# The migration that owns agent_registry_lifecycle_state_check today. If a later
# migration recreates that constraint, point this at the one that runs LAST —
# its vocabulary is the one the running database has. Repointing it at an
# earlier file turns this test green while leaving the constraint wrong, which
# is the same trap test_audit_event_types.py documents for event types.
CONSTRAINT_MIGRATION = MIGRATIONS_DIR / "009_agent_lifecycle_states.sql"

# Permitted states that the dashboard deliberately does not offer as a fleet
# filter, each with the reason it is absent rather than missing.
#
#   decommissioned — admitted by 009 only because agent_registry.status already
#                    carried it in its own CHECK, so the two columns on one
#                    table disagreed about whether the state exists. No code
#                    path writes it to lifecycle_state. Offering it as a filter
#                    would be a control that can only ever return zero rows.
#
# An entry here must still be permitted by the constraint; a stale one fails
# `test_no_stale_unfiltered_state`.
UNFILTERED_PERMITTED_STATES = {"decommissioned"}

# The 'all' sentinel is the UI's "no filter" option, not a lifecycle state.
FILTER_SENTINELS = {"all"}


def _permitted_states() -> set[str]:
    """Values inside the migration's ``CHECK (lifecycle_state IN (...))``."""
    sql = CONSTRAINT_MIGRATION.read_text()
    # Strip SQL comments first. This migration explains the defect at length and
    # names states in prose; counting a quoted word in a comment as permitted
    # would let a genuinely forbidden state through.
    stripped = "\n".join(re.sub(r"--.*$", "", line) for line in sql.splitlines())
    match = re.search(
        r"CHECK\s*\(\s*lifecycle_state\s+IN\s*\((.*?)\)\s*\)", stripped, re.S | re.I,
    )
    assert match is not None, (
        f"no CHECK (lifecycle_state IN (...)) found in {CONSTRAINT_MIGRATION.name}. "
        "The guard cannot read the permitted vocabulary, so it fails rather than "
        "reporting agreement it did not verify."
    )
    return set(re.findall(r"'([^']+)'", match.group(1)))


def _states_written_by_source() -> set[str]:
    """Lifecycle states the application writes, read out of the statements.

    Two shapes, both present in api_compat.py:

    * a literal in the INSERT that creates an agent, and any
      ``SET lifecycle_state = '<literal>'`` update;
    * a module constant such as ``STUNNED_LIFECYCLE_STATE``, which is what the
      stun path passes as a query parameter.

    Parameterised writes ($1) are deliberately *not* guessed at — the constant
    lookup is what resolves them, and a value reaching the column by any route
    this cannot see is a gap named in the module docstring rather than papered
    over with a plausible default.
    """
    source = API_COMPAT.read_text()
    states: set[str] = set()

    # INSERT INTO agent_registry (... lifecycle_state ...) VALUES (... 'x' ...)
    for insert in re.finditer(
        r"INSERT\s+INTO\s+agent_registry\s*\((?P<cols>[^)]*)\)\s*"
        r"VALUES\s*\((?P<vals>[^)]*)\)",
        source, re.S | re.I,
    ):
        columns = [c.strip() for c in insert.group("cols").split(",")]
        values = [v.strip() for v in insert.group("vals").split(",")]
        if "lifecycle_state" in columns and len(columns) == len(values):
            value = values[columns.index("lifecycle_state")]
            if value.startswith("'") and value.endswith("'"):
                states.add(value.strip("'"))

    # UPDATE ... SET lifecycle_state = 'literal'
    states.update(
        re.findall(r"SET\s+lifecycle_state\s*=\s*'([^']+)'", source, re.I),
    )

    # Module constants naming a lifecycle state.
    tree = ast.parse(source)
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not isinstance(node.value, ast.Constant) or not isinstance(node.value.value, str):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id.endswith("_LIFECYCLE_STATE"):
                states.add(node.value.value)

    return states


def _offered_transition_targets() -> set[str]:
    """States AgentDetailPage offers as transition destinations.

    The table is ``{ state: 'x', label: '...' }`` entries keyed by current
    state, so the destinations are the ``state:`` values.
    """
    text = AGENT_DETAIL.read_text()
    return set(re.findall(r"\{\s*state:\s*'([^']+)'", text))


# ── mechanism checks ────────────────────────────────────────────────────


def test_the_constraint_permits_states_at_all() -> None:
    assert len(_permitted_states()) >= 4


def test_the_source_writes_states_at_all() -> None:
    written = _states_written_by_source()
    assert len(written) >= 2, (
        f"only resolved {written} from api_compat.py. The extractor is probably "
        "broken; an empty result would make every test below pass vacuously."
    )


def test_the_dashboard_offers_states_at_all() -> None:
    assert len(_array_literal(AGENTS_PAGE, "LIFECYCLE_OPTIONS")) >= 3
    assert len(_offered_transition_targets()) >= 2


# ── the seams ───────────────────────────────────────────────────────────


def test_every_state_the_api_writes_is_permitted() -> None:
    """Migration 009's defect, stated as a standing assertion.

    Writing a state the constraint forbids raises CheckViolationError, rolls
    back the mutation it shares a transaction with, and returns 500. It is
    invisible to the tier-1 suite because the fixture store is a dict.
    """
    rejected = sorted(_states_written_by_source() - _permitted_states())
    assert not rejected, (
        f"{len(rejected)} lifecycle state(s) written by api_compat.py are not "
        f"permitted by {CONSTRAINT_MIGRATION.name}: {rejected}. Every write of "
        "these raises CheckViolationError and 500s. Widen the constraint in a "
        "new migration."
    )


def test_every_state_the_api_writes_is_filterable() -> None:
    """An agent in a state the fleet view cannot select for is invisible.

    'registered' is the case that motivated this: the create path hardcodes it,
    so every agent the product makes starts there, and the Agents page offered
    no way to filter to them.
    """
    offered = set(_array_literal(AGENTS_PAGE, "LIFECYCLE_OPTIONS")) - FILTER_SENTINELS
    missing = sorted(_states_written_by_source() - offered)
    assert not missing, (
        f"{len(missing)} lifecycle state(s) the API writes have no filter option "
        f"in AgentsPage.tsx: {missing}. Agents occupy these states and the fleet "
        "view provides no way to select them. Add them to LIFECYCLE_OPTIONS "
        "(and LIFECYCLE_LABELS)."
    )


def test_every_offered_transition_target_is_permitted() -> None:
    """A button that always 500s.

    AgentDetailPage offers transition destinations directly to the operator. A
    destination the constraint forbids cannot be written, so pressing it raises
    CheckViolationError and returns 500 — and only that one button is affected,
    so it survives any test that does not press it.
    """
    forbidden = sorted(_offered_transition_targets() - _permitted_states())
    assert not forbidden, (
        f"{len(forbidden)} transition target(s) offered by AgentDetailPage.tsx "
        f"are not permitted by the lifecycle_state constraint: {forbidden}. "
        "Selecting one returns 500."
    )


def test_no_dead_lifecycle_filter_options() -> None:
    """A filter option for a state no row can hold returns zero rows forever."""
    offered = set(_array_literal(AGENTS_PAGE, "LIFECYCLE_OPTIONS")) - FILTER_SENTINELS
    dead = sorted(offered - _permitted_states())
    assert not dead, (
        f"{len(dead)} filter option(s) in AgentsPage.tsx name states the "
        f"lifecycle_state constraint forbids: {dead}. No row can hold them, so "
        "the filter can only ever return nothing."
    )


def test_no_stale_unfiltered_state() -> None:
    """An exemption whose target no longer exists is itself drift."""
    permitted = _permitted_states()
    stale = sorted(UNFILTERED_PERMITTED_STATES - permitted)
    assert not stale, (
        f"{len(stale)} entry(ies) in UNFILTERED_PERMITTED_STATES are no longer "
        f"permitted by the constraint: {stale}. Remove them from the allowlist — "
        "an exemption for a state that cannot exist hides nothing and misleads "
        "the next reader."
    )
