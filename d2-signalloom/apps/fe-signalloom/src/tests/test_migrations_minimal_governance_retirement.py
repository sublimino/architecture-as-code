"""075 retires 'minimal_governance': static shape checks.

Tier 1 (no DATABASE_URL needed) -- inspects the migration's own SQL text, the
same technique test_audit_event_types.py uses for the CHECK constraint. The
behavioural proof against a real schema (the remap actually happening, a
no-op on an unrelated row) is Tier 2, in
test_migrations_integration.py::test_a_tenant_recorded_as_minimal_governance_is_remapped_to_eap_view.
"""
from __future__ import annotations

import re
from pathlib import Path

from db.migrate import MIGRATIONS_DIR

MIGRATION = MIGRATIONS_DIR / "075_retire_minimal_governance_account_type.sql"


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_the_migration_file_exists() -> None:
    assert MIGRATION.is_file(), f"{MIGRATION.name} is missing from {MIGRATIONS_DIR}"


def test_it_targets_tenant_account_types_rows_named_minimal_governance() -> None:
    sql = _sql()
    update_match = re.search(
        r"UPDATE\s+public\.tenant_account_types\s+SET(.*?)WHERE\s+account_type\s*=\s*'minimal_governance'",
        sql, re.S | re.I,
    )
    assert update_match is not None, (
        "no 'UPDATE public.tenant_account_types ... WHERE account_type = "
        "'minimal_governance'' statement found"
    )


def test_it_remaps_to_eap_view_and_marks_customised() -> None:
    sql = _sql()
    update_match = re.search(
        r"UPDATE\s+public\.tenant_account_types\s+SET(.*?)WHERE\s+account_type\s*=\s*'minimal_governance'",
        sql, re.S | re.I,
    )
    assert update_match is not None
    set_clause = update_match.group(1)
    assert re.search(r"account_type\s*=\s*'eap_view'", set_clause, re.I), (
        "the remap target must be 'eap_view' -- the nearest supported account "
        "type by flag-set distance"
    )
    assert re.search(r"customised\s*=\s*TRUE", set_clause, re.I), (
        "the remapped row must be marked customised: the tenant's actual flags "
        "are untouched by this migration and do not equal eap_view's set"
    )


def test_it_does_not_touch_tenant_feature_flags() -> None:
    """Only the recorded TYPE label moves. The flags themselves (057) are the
    tenant's real configuration and this migration must not rewrite them."""
    assert not re.search(r"(?:UPDATE|INSERT\s+INTO)\s+public\.tenant_feature_flags", _sql(), re.I)


def test_it_is_wrapped_in_a_transaction() -> None:
    sql = _sql()
    assert re.search(r"^\s*BEGIN;", sql, re.M)
    assert re.search(r"^\s*COMMIT;", sql, re.M)
