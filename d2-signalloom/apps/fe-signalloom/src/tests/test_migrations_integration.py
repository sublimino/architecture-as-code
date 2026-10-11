"""The migration runner against a real PostgreSQL server.

Skipped unless ``DATABASE_URL`` is set, matching the Tier 2 convention.

This is the test that would have caught the defect the runner exists to fix: a
database provisioned *before* 005 existed must gain the three scan-preference
columns on its own, with no hand-applied SQL.  Everything runs inside a scratch
database that is dropped on the way out; the demo database is never touched.
"""
from __future__ import annotations

import os
import shutil
import uuid
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest
try:
    import pytest_asyncio
    _async_fixture = pytest_asyncio.fixture
except ImportError:
    pytest_asyncio = None
    _async_fixture = pytest.fixture

from db.migrate import MIGRATIONS_DIR, apply_migrations, discover_migrations

# Derived dynamically — never hand-listed.
ALL_MIGRATIONS = [m.filename for m in discover_migrations(MIGRATIONS_DIR)]

DATABASE_URL = os.environ.get("DATABASE_URL")

pytestmark = pytest.mark.skipif(
    DATABASE_URL is None or pytest_asyncio is None,
    reason="DATABASE_URL not set or pytest_asyncio missing -- migration integration tests require a live Postgres",
)

PRE_005_MIGRATIONS = [
    "001_discovery_tables.sql",
    "002_add_report_url_to_sessions.sql",
    "003_platform_backends.sql",
    "004_agent_governance_schema.sql",
]
NEW_COLUMNS = ("preferred_scan_cadence_hours", "alert_email", "alert_threshold")

#: The columns 062 adds, holding what a tenant DECLARES about itself at
#: onboarding: where it operates, what it does, what a loss costs it.
RISK_PROFILE_COLUMNS = (
    "sector",
    "jurisdiction",
    "reporting_currency",
    "risk_appetite_tolerance",
    "risk_load",
)


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


@_async_fixture
async def scratch_dsn():
    """A throwaway database, dropped however the test ends."""
    name = f"signalloom_migtest_{uuid.uuid4().hex[:12]}"
    admin = await asyncpg.connect(DATABASE_URL)
    try:
        await admin.execute(f'CREATE DATABASE "{name}"')
    finally:
        await admin.close()
    try:
        yield _with_database(DATABASE_URL, name)
    finally:
        admin = await asyncpg.connect(DATABASE_URL)
        try:
            await admin.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1",
                name,
            )
            await admin.execute(f'DROP DATABASE IF EXISTS "{name}"')
        finally:
            await admin.close()


@_async_fixture
async def scratch_pool(scratch_dsn: str):
    pool = await asyncpg.create_pool(scratch_dsn, min_size=1, max_size=2)
    try:
        yield pool
    finally:
        await pool.close()


async def _columns(pool: asyncpg.Pool, table: str) -> set[str]:
    rows = await pool.fetch(
        """SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = $1""",
        table,
    )
    return {row["column_name"] for row in rows}


def _pre_005_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "pre-005"
    directory.mkdir()
    for filename in PRE_005_MIGRATIONS:
        shutil.copy(MIGRATIONS_DIR / filename, directory / filename)
    return directory


@pytest.mark.asyncio
async def test_runner_adds_the_scan_preference_columns_to_an_existing_database(
    scratch_pool: asyncpg.Pool, tmp_path: Path,
) -> None:
    # A database provisioned before 005 existed -- exactly the cluster's state.
    await apply_migrations(scratch_pool, _pre_005_dir(tmp_path))
    before = await _columns(scratch_pool, "tenant_settings")
    assert before, "001-004 should have created tenant_settings"
    assert not (before & set(NEW_COLUMNS)), "precondition: the columns must be absent"

    applied = await apply_migrations(scratch_pool)

    assert applied == ALL_MIGRATIONS[len(PRE_005_MIGRATIONS):]
    after = await _columns(scratch_pool, "tenant_settings")
    assert set(NEW_COLUMNS) <= after


@pytest.mark.asyncio
async def test_the_new_columns_carry_the_documented_defaults(
    scratch_pool: asyncpg.Pool,
) -> None:
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-defaults", "Defaults Org",
    )

    row = await scratch_pool.fetchrow(
        """SELECT preferred_scan_cadence_hours, alert_email, alert_threshold
             FROM public.tenant_settings WHERE tenant_id = $1""",
        "tenant-defaults",
    )

    assert row["preferred_scan_cadence_hours"] == 24
    assert row["alert_email"] is None
    assert row["alert_threshold"] == 1


@pytest.mark.asyncio
async def test_nonsense_preferences_are_rejected_by_the_check_constraints(
    scratch_pool: asyncpg.Pool,
) -> None:
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-checks", "Checks Org",
    )

    for column in ("preferred_scan_cadence_hours", "alert_threshold"):
        with pytest.raises(asyncpg.CheckViolationError):
            await scratch_pool.execute(
                f"UPDATE public.tenant_settings SET {column} = 0 WHERE tenant_id = $1",
                "tenant-checks",
            )


@pytest.mark.asyncio
async def test_a_second_run_against_a_migrated_database_is_a_no_op(
    scratch_pool: asyncpg.Pool,
) -> None:
    first = await apply_migrations(scratch_pool)
    assert len(first) == len(ALL_MIGRATIONS)

    second = await apply_migrations(scratch_pool)

    assert second == []
    recorded = await scratch_pool.fetch(
        "SELECT version, filename FROM public.schema_migrations ORDER BY version",
    )
    assert [row["filename"] for row in recorded] == ALL_MIGRATIONS


@pytest.mark.asyncio
async def test_the_runner_agrees_with_the_bootstrap_sql(
    scratch_pool: asyncpg.Pool,
) -> None:
    """A fresh cluster runs the bootstrap; the runner must then be a no-op-ish.

    The bootstrap is the concatenation of the same files, so applying it first
    and then running the runner must leave the same schema and must not error.
    """
    bootstrap = (
        Path(__file__).resolve().parents[4]
        / "contracts" / "discovery-portal-bootstrap.sql"
    )
    assert bootstrap.is_file(), bootstrap
    await scratch_pool.execute(bootstrap.read_text(encoding="utf-8"))

    applied = await apply_migrations(scratch_pool)

    # Every migration re-runs once (the ledger is new) and every one is a no-op.
    assert len(applied) == len(ALL_MIGRATIONS)
    assert set(NEW_COLUMNS) <= await _columns(scratch_pool, "tenant_settings")


# ---------------------------------------------------------------------------
# 062 -- the declared organisational risk profile
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_the_risk_profile_columns_are_added_to_tenant_settings(
    scratch_pool: asyncpg.Pool,
) -> None:
    await apply_migrations(scratch_pool)

    assert set(RISK_PROFILE_COLUMNS) <= await _columns(scratch_pool, "tenant_settings")


@pytest.mark.asyncio
async def test_a_tenant_that_declares_nothing_is_still_valid(
    scratch_pool: asyncpg.Pool,
) -> None:
    """Declining to declare a risk profile must not make a tenant unsavable.

    Every column is nullable with no default, so a tenant that skips the step
    reads back as all-NULL rather than as a fabricated posture.  This is the
    test that pins "no existing figure moves unless a tenant opts in" at the
    storage layer: there is no default for the engine to pick up.
    """
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-undeclared", "Undeclared Org",
    )

    row = await scratch_pool.fetchrow(
        """SELECT sector, jurisdiction, reporting_currency,
                  risk_appetite_tolerance, risk_load
             FROM public.tenant_settings WHERE tenant_id = $1""",
        "tenant-undeclared",
    )

    assert all(row[column] is None for column in RISK_PROFILE_COLUMNS)


@pytest.mark.asyncio
async def test_a_full_risk_profile_round_trips(
    scratch_pool: asyncpg.Pool,
) -> None:
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-declared", "Declared Org",
    )

    await scratch_pool.execute(
        """UPDATE public.tenant_settings
              SET sector = $1, jurisdiction = $2, reporting_currency = $3,
                  risk_appetite_tolerance = $4, risk_load = $5
            WHERE tenant_id = $6""",
        "healthcare-provider", "US", "USD", 6000, 0.25, "tenant-declared",
    )

    row = await scratch_pool.fetchrow(
        """SELECT sector, jurisdiction, reporting_currency,
                  risk_appetite_tolerance, risk_load
             FROM public.tenant_settings WHERE tenant_id = $1""",
        "tenant-declared",
    )

    assert row["sector"] == "healthcare-provider"
    assert row["jurisdiction"] == "US"
    assert row["reporting_currency"] == "USD"
    assert float(row["risk_appetite_tolerance"]) == 6000.0
    assert row["risk_load"] == 0.25


@pytest.mark.asyncio
async def test_a_malformed_currency_code_is_rejected_at_the_storage_layer(
    scratch_pool: asyncpg.Pool,
) -> None:
    """An unvalidated currency code reaches the screen looking like real money.

    ``Intl.NumberFormat`` RENDERS an unrecognised code rather than throwing, so
    a bad value stored here is not a crash -- it is a figure that reads as a
    priced number and is not one.  The shape CHECK is the floor under that, and
    it binds every writer, not just the handler that happens to validate.
    """
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-currency", "Currency Org",
    )

    for bad in ("gbp", "GB", "GBPP", "G8P", "", "   "):
        with pytest.raises(asyncpg.CheckViolationError):
            await scratch_pool.execute(
                "UPDATE public.tenant_settings SET reporting_currency = $1 WHERE tenant_id = $2",
                bad, "tenant-currency",
            )


@pytest.mark.asyncio
async def test_a_non_finite_or_negative_risk_load_is_rejected(
    scratch_pool: asyncpg.Pool,
) -> None:
    """NaN is the case a plain ``>= 0`` check lets through.

    PostgreSQL sorts NaN above every other value, so ``'NaN'::float8 >= 0`` is
    TRUE -- a NaN risk_load would satisfy a naive non-negativity check, then
    propagate through ``tvar * (1 + risk_load)`` and produce a carried figure
    that is not a number.  The ``< 'Infinity'`` conjunct is what actually
    rejects it (NaN compares as greater than Infinity), and it catches +Inf in
    the same breath.  Verified against postgres:16, not assumed.
    """
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-load", "Load Org",
    )

    for bad in (float("nan"), float("inf"), -0.01, -1.0):
        with pytest.raises(asyncpg.CheckViolationError):
            await scratch_pool.execute(
                "UPDATE public.tenant_settings SET risk_load = $1 WHERE tenant_id = $2",
                bad, "tenant-load",
            )

    # Zero is a coherent posture: charge the tail with no load on top.
    await scratch_pool.execute(
        "UPDATE public.tenant_settings SET risk_load = 0 WHERE tenant_id = $1",
        "tenant-load",
    )


@pytest.mark.asyncio
async def test_a_non_positive_or_non_finite_appetite_tolerance_is_rejected(
    scratch_pool: asyncpg.Pool,
) -> None:
    """Without a tolerance band a number cannot become a verdict.

    Same validation as ``LoadOrgRiskPosture`` applies to appetite.tolerance, and
    the same NaN trap applies: ``'NaN'::numeric > 0`` is TRUE.
    """
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-tolerance", "Tolerance Org",
    )

    for bad in (0, -1, float("nan")):
        with pytest.raises(asyncpg.CheckViolationError):
            await scratch_pool.execute(
                "UPDATE public.tenant_settings SET risk_appetite_tolerance = $1 WHERE tenant_id = $2",
                bad, "tenant-tolerance",
            )


@pytest.mark.asyncio
async def test_jurisdiction_and_sector_must_be_canonical_and_non_blank(
    scratch_pool: asyncpg.Pool,
) -> None:
    """A blank declaration must not be storable as if it were a declaration.

    ``Scenario.AppliesTo`` treats an EMPTY jurisdiction as matching no scoped
    scenario, and a whitespace-only string trims to empty -- so a blank stored
    here would be indistinguishable from NULL in behaviour while reading as
    "declared" in the UI.  Jurisdiction is additionally pinned to its
    trimmed-uppercase form: AppliesTo is case-insensitive, so storing both 'uk'
    and 'UK' buys nothing and makes two rows that differ only by case.
    """
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-juris", "Juris Org",
    )

    for bad in ("", "  ", "uk", " UK"):
        with pytest.raises(asyncpg.CheckViolationError):
            await scratch_pool.execute(
                "UPDATE public.tenant_settings SET jurisdiction = $1 WHERE tenant_id = $2",
                bad, "tenant-juris",
            )

    for bad in ("", "   "):
        with pytest.raises(asyncpg.CheckViolationError):
            await scratch_pool.execute(
                "UPDATE public.tenant_settings SET sector = $1 WHERE tenant_id = $2",
                bad, "tenant-juris",
            )

    # Global is expressible, and is NOT the same as declining to declare.
    await scratch_pool.execute(
        "UPDATE public.tenant_settings SET jurisdiction = $1 WHERE tenant_id = $2",
        "*", "tenant-juris",
    )


@pytest.mark.asyncio
async def test_the_handlers_own_update_statement_runs_against_the_real_schema(
    scratch_pool: asyncpg.Pool,
) -> None:
    """The pooled write path, against Postgres rather than a fake.

    ``test_tenant_risk_profile.py`` exercises the handler over the in-memory
    fixture store, which proves the contract but never compiles the SQL.  The
    two things most likely to be wrong are exactly the two a fake cannot see:
    that the statement is valid against the real column set, and that
    ``risk_appetite_tolerance`` binds at all -- it is NUMERIC, and asyncpg
    rejects a Python float for a numeric parameter outright rather than
    coercing it, so the handler converts to Decimal.  This test fails if either
    the statement or that conversion regresses.
    """
    await apply_migrations(scratch_pool)
    await scratch_pool.execute(
        "INSERT INTO public.tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
        "tenant-handler-sql", "Handler SQL Org",
    )

    # Byte-for-byte the statement in api_compat.patch_tenant_risk_profile.
    statement = """UPDATE tenant_settings
                  SET sector                  = $1,
                      jurisdiction            = $2,
                      reporting_currency      = $3,
                      risk_appetite_tolerance = $4,
                      risk_load               = $5
                WHERE tenant_id = $6"""

    await scratch_pool.execute(
        statement,
        "retail-ecommerce", "UK", "GBP", Decimal("25000.00"), 0.15, "tenant-handler-sql",
    )

    row = await scratch_pool.fetchrow(
        """SELECT sector, jurisdiction, reporting_currency,
                  risk_appetite_tolerance, risk_load
             FROM public.tenant_settings WHERE tenant_id = $1""",
        "tenant-handler-sql",
    )
    assert row["sector"] == "retail-ecommerce"
    assert row["jurisdiction"] == "UK"
    assert row["reporting_currency"] == "GBP"
    assert row["risk_appetite_tolerance"] == Decimal("25000.00")
    assert row["risk_load"] == 0.15

    # And the all-undeclared write, which is what skipping the step sends.
    await scratch_pool.execute(
        statement, None, None, None, None, None, "tenant-handler-sql",
    )
    cleared = await scratch_pool.fetchrow(
        """SELECT sector, jurisdiction, reporting_currency,
                  risk_appetite_tolerance, risk_load
             FROM public.tenant_settings WHERE tenant_id = $1""",
        "tenant-handler-sql",
    )
    assert all(cleared[column] is None for column in RISK_PROFILE_COLUMNS)
