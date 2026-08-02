"""The event types the code writes must be permitted by the CHECK constraint.

Every ``_audit_log()`` call site wrote a dotted event type while the constraint
allowed only an undotted vocabulary. The two sets were completely disjoint, so
every audit insert raised ``CheckViolationError`` — the business write had
already committed as a separate statement, so the endpoint persisted its change
and then returned 500. ``audit_events`` held zero rows on a cluster that had
been running for days.

Nothing caught it because the vocabulary lived in two places: string literals in
``api_compat.py`` and a hand-maintained list in SQL. 004 created the constraint,
006 widened it, and neither noticed that no call site used any of the values.

So this test derives both sides rather than restating either. The literals come
from the AST of ``api_compat.py``, the permitted values from the migration SQL.
Adding a call site with a new event type fails here instead of 500ing at
runtime.
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

SRC_DIR = Path(__file__).resolve().parent.parent
API_COMPAT = SRC_DIR / "api_compat.py"
MIGRATIONS_DIR = SRC_DIR / "db" / "migrations"

# The migration that owns the constraint today. When a later migration widens it
# again, point this at that file — the test will then track the newer list.
# Must name the LAST migration that recreates audit_events_event_type_check,
# because that is the one whose vocabulary survives. 010_agent_credentials.sql
# and 011_agent_stunned_event_type.sql both drop-and-recreate that constraint;
# 011 runs second and carries the union of both event sets, so it is the file
# that describes the runtime constraint.
#
# Repointing this line is exactly the wrong instinct when this test goes red
# after a merge: it turns the test green while leaving the database constraint
# missing an event type. Point it at whichever migration runs LAST, and make
# that migration enumerate every type.
CONSTRAINT_MIGRATION = MIGRATIONS_DIR / "011_agent_stunned_event_type.sql"


def _emitted_event_types() -> set[str]:
    """Every literal passed as ``event_type`` to ``_audit_log``.

    Parsed rather than grepped: a regex over source silently misses a call
    whose arguments wrap differently, and a guard that misses call sites is
    worse than no guard because it reads as coverage.

    ``_audit_log(executor, tenant_id, event_type, agent_id, control_id, actor,
    detail)`` — third positional, or the ``event_type`` keyword.
    """
    tree = ast.parse(API_COMPAT.read_text())
    emitted: set[str] = set()

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        if name != "_audit_log":
            continue

        if len(node.args) >= 3 and isinstance(node.args[2], ast.Constant):
            value = node.args[2].value
            if isinstance(value, str):
                emitted.add(value)
        for keyword in node.keywords:
            if keyword.arg == "event_type" and isinstance(keyword.value, ast.Constant):
                if isinstance(keyword.value.value, str):
                    emitted.add(keyword.value.value)

    return emitted


def _permitted_event_types() -> set[str]:
    """The values inside the migration's ``CHECK (event_type IN (...))``."""
    sql = CONSTRAINT_MIGRATION.read_text()
    match = re.search(r"CHECK\s*\(\s*event_type\s+IN\s*\((.*?)\)\s*\)", sql, re.S | re.I)
    assert match is not None, f"no CHECK (event_type IN (...)) found in {CONSTRAINT_MIGRATION.name}"
    return set(re.findall(r"'([^']+)'", match.group(1)))


def test_the_source_emits_event_types_at_all() -> None:
    """Guards the guard: an extractor that finds nothing would pass vacuously."""
    emitted = _emitted_event_types()
    assert len(emitted) >= 10, f"only found {len(emitted)} event types — extractor is probably broken"


def test_the_migration_permits_values_at_all() -> None:
    permitted = _permitted_event_types()
    assert len(permitted) >= 10, f"only parsed {len(permitted)} permitted values — parser is probably broken"


def test_every_emitted_event_type_is_permitted() -> None:
    """The regression guard. This is the bug, stated as an assertion."""
    emitted = _emitted_event_types()
    permitted = _permitted_event_types()
    rejected = sorted(emitted - permitted)
    assert not rejected, (
        f"{len(rejected)} event type(s) written by _audit_log are not permitted by "
        f"{CONSTRAINT_MIGRATION.name}: {rejected}. Every insert of these raises "
        "CheckViolationError at runtime, and because the mutation commits first, "
        "the endpoint persists its change and then returns 500. Add them to the "
        "constraint in a new migration."
    )


def test_emitted_event_types_use_the_dotted_convention() -> None:
    """Thirteen call sites use ``area.action``; keep new ones consistent."""
    odd = sorted(t for t in _emitted_event_types() if "." not in t)
    assert not odd, (
        f"event types not using the dotted area.action convention: {odd}. "
        "The undotted names in the constraint are retained legacy values that "
        "no call site emits."
    )
