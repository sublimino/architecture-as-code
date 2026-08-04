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
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest
import pytest_asyncio

from db.migrate import MIGRATIONS_DIR, apply_migrations, discover_migrations

# Derived dynamically — never hand-listed.
ALL_MIGRATIONS = [m.filename for m in discover_migrations(MIGRATIONS_DIR)]

DATABASE_URL = os.environ.get("DATABASE_URL")

pytestmark = pytest.mark.skipif(
    DATABASE_URL is None,
    reason="DATABASE_URL not set -- migration integration tests require a live Postgres",
)

PRE_005_MIGRATIONS = [
    "001_discovery_tables.sql",
    "002_add_report_url_to_sessions.sql",
    "003_platform_backends.sql",
    "004_agent_governance_schema.sql",
]
NEW_COLUMNS = ("preferred_scan_cadence_hours", "alert_email", "alert_threshold")


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


@pytest_asyncio.fixture
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


@pytest_asyncio.fixture
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
