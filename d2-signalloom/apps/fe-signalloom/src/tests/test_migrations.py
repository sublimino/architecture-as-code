"""Hermetic tests for the startup schema-migration runner.

The runner exists because ``/docker-entrypoint-initdb.d`` only executes on an
empty data directory, so every already-provisioned database silently missed
every migration added after it was created.  These tests drive the runner
against a recording fake Postgres; ``test_migrations_integration.py`` proves the
same behaviour against a real server.
"""
from __future__ import annotations

import shutil
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import pytest

from db.migrate import (
    ADVISORY_LOCK_KEY,
    MIGRATIONS_DIR,
    MigrationError,
    apply_migrations,
    discover_migrations,
)

# Derived from the migrations directory, never hand-listed. A literal here has
# to be updated by every future migration, and when it is not, these tests fail
# for a reason that has nothing to do with the runner they are testing —
# which is exactly what happened when 006 landed.
REPO_MIGRATIONS = [migration.filename for migration in discover_migrations(MIGRATIONS_DIR)]


# ---------------------------------------------------------------------------
# Recording fake Postgres
# ---------------------------------------------------------------------------

class _FakeConnection:
    def __init__(self, server: "FakePostgres") -> None:
        self._server = server

    async def execute(self, query: str, *args: Any) -> None:
        server = self._server
        if "pg_advisory_lock" in query:
            server.lock_events.append(("lock", args[0]))
            return
        if "pg_advisory_unlock" in query:
            server.lock_events.append(("unlock", args[0]))
            return
        if "CREATE TABLE IF NOT EXISTS public.schema_migrations" in query:
            if not server.lock_events:
                raise AssertionError("the ledger was created before the lock was taken")
            server.ledger_created = True
            return
        if "INSERT INTO public.schema_migrations" in query:
            version, filename = args
            server.ledger.append((version, filename))
            return
        # Anything else is a migration body.
        if server.fail_on is not None and server.fail_on in query:
            raise RuntimeError('syntax error at or near "OOPS"')
        server.executed.append(query)

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        if "FROM public.schema_migrations" in query:
            if not self._server.ledger_created:
                raise AssertionError("the ledger was read before it was created")
            return [{"version": version} for version, _ in self._server.ledger]
        raise AssertionError(f"unexpected fetch: {query}")


class FakePostgres:
    """Just enough asyncpg.Pool to drive the runner and record what it did."""

    def __init__(self, fail_on: str | None = None) -> None:
        self.fail_on = fail_on
        self.ledger: list[tuple[str, str]] = []
        self.ledger_created = False
        self.executed: list[str] = []
        self.lock_events: list[tuple[str, int]] = []

    @asynccontextmanager
    async def acquire(self):
        yield _FakeConnection(self)


def _migration_dir(tmp_path: Path, filenames: list[str]) -> Path:
    directory = tmp_path / "migrations"
    directory.mkdir()
    for filename in filenames:
        shutil.copy(MIGRATIONS_DIR / filename, directory / filename)
    return directory


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def test_migrations_are_discovered_in_filename_order() -> None:
    assert [m.filename for m in discover_migrations()] == REPO_MIGRATIONS


def test_discovery_orders_numerically_not_lexicographically(tmp_path: Path) -> None:
    directory = tmp_path / "migrations"
    directory.mkdir()
    for name in ("002_second.sql", "010_tenth.sql", "001_first.sql"):
        (directory / name).write_text("SELECT 1;\n", encoding="utf-8")

    assert [m.filename for m in discover_migrations(directory)] == [
        "001_first.sql", "002_second.sql", "010_tenth.sql",
    ]


def test_an_unparseable_filename_is_refused_rather_than_guessed(tmp_path: Path) -> None:
    directory = tmp_path / "migrations"
    directory.mkdir()
    (directory / "001_ok.sql").write_text("SELECT 1;\n", encoding="utf-8")
    (directory / "hotfix.sql").write_text("SELECT 1;\n", encoding="utf-8")

    with pytest.raises(MigrationError, match="ambiguous migration filename: hotfix.sql"):
        discover_migrations(directory)


def test_a_duplicated_version_is_refused(tmp_path: Path) -> None:
    directory = tmp_path / "migrations"
    directory.mkdir()
    (directory / "001_first.sql").write_text("SELECT 1;\n", encoding="utf-8")
    (directory / "001_also-first.sql").write_text("SELECT 1;\n", encoding="utf-8")

    with pytest.raises(MigrationError, match="duplicate migration version 1"):
        discover_migrations(directory)


def test_an_empty_migrations_directory_is_an_error(tmp_path: Path) -> None:
    directory = tmp_path / "migrations"
    directory.mkdir()

    with pytest.raises(MigrationError, match="no migrations found"):
        discover_migrations(directory)


# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_migrations_are_applied_in_order_on_a_fresh_database() -> None:
    server = FakePostgres()

    applied = await apply_migrations(server)

    assert applied == REPO_MIGRATIONS
    assert [filename for _, filename in server.ledger] == REPO_MIGRATIONS
    assert len(server.executed) == len(REPO_MIGRATIONS)


@pytest.mark.asyncio
async def test_the_ledger_records_version_and_filename() -> None:
    server = FakePostgres()

    await apply_migrations(server)

    assert server.ledger == [
        (migration.version, migration.filename)
        for migration in discover_migrations(MIGRATIONS_DIR)
    ]


@pytest.mark.asyncio
async def test_a_second_startup_applies_nothing() -> None:
    server = FakePostgres()
    await apply_migrations(server)
    executed_after_first = list(server.executed)

    applied = await apply_migrations(server)

    assert applied == []
    assert server.executed == executed_after_first
    assert [filename for _, filename in server.ledger] == REPO_MIGRATIONS


@pytest.mark.asyncio
async def test_only_the_missing_migrations_are_applied(tmp_path: Path) -> None:
    """The shape of an existing cluster: every migration but the newest present."""
    server = FakePostgres()
    await apply_migrations(server, _migration_dir(tmp_path, REPO_MIGRATIONS[:-1]))

    applied = await apply_migrations(server)

    assert applied == REPO_MIGRATIONS[-1:]


@pytest.mark.asyncio
async def test_the_apply_is_serialised_behind_an_advisory_lock() -> None:
    server = FakePostgres()

    await apply_migrations(server)

    assert server.lock_events == [
        ("lock", ADVISORY_LOCK_KEY),
        ("unlock", ADVISORY_LOCK_KEY),
    ]


# ---------------------------------------------------------------------------
# Failure surfaces
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_a_failing_migration_raises_and_names_the_file() -> None:
    server = FakePostgres(fail_on="platform_backends")

    with pytest.raises(MigrationError, match="003_platform_backends.sql"):
        await apply_migrations(server)


@pytest.mark.asyncio
async def test_a_failing_migration_is_not_recorded_and_stops_the_run() -> None:
    server = FakePostgres(fail_on="platform_backends")

    with pytest.raises(MigrationError):
        await apply_migrations(server)

    # 001 and 002 committed; 003 failed; 004 and 005 never ran.
    assert [filename for _, filename in server.ledger] == REPO_MIGRATIONS[:2]
    assert len(server.executed) == 2


@pytest.mark.asyncio
async def test_the_advisory_lock_is_released_even_when_a_migration_fails() -> None:
    server = FakePostgres(fail_on="platform_backends")

    with pytest.raises(MigrationError):
        await apply_migrations(server)

    assert server.lock_events == [
        ("lock", ADVISORY_LOCK_KEY),
        ("unlock", ADVISORY_LOCK_KEY),
    ]


@pytest.mark.asyncio
async def test_the_underlying_error_is_kept_as_the_cause() -> None:
    server = FakePostgres(fail_on="platform_backends")

    with pytest.raises(MigrationError) as excinfo:
        await apply_migrations(server)

    assert isinstance(excinfo.value.__cause__, RuntimeError)
    assert "syntax error" in str(excinfo.value)


@pytest.mark.asyncio
async def test_a_missing_migrations_directory_surfaces(tmp_path: Path) -> None:
    with pytest.raises(MigrationError, match="migrations directory not found"):
        await apply_migrations(FakePostgres(), tmp_path / "nope")


# ---------------------------------------------------------------------------
# Regression guard for the defect that motivated the runner
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_the_scan_preference_columns_are_part_of_what_gets_applied() -> None:
    """The three columns whose absence produced UndefinedColumnError."""
    server = FakePostgres()

    await apply_migrations(server)

    body = next(sql for sql in server.executed if "preferred_scan_cadence_hours" in sql)
    for column in ("preferred_scan_cadence_hours", "alert_email", "alert_threshold"):
        assert f"ADD COLUMN IF NOT EXISTS {column}" in body


@pytest.mark.asyncio
async def test_every_repo_migration_is_idempotent_by_construction() -> None:
    """The runner is the belt to the bootstrap's braces; they must not disagree.

    A migration that is not safe to re-run against a database the bootstrap has
    already provisioned would make the two paths conflict, so every DDL verb we
    use must carry an existence guard.
    """
    def statements_only(text: str) -> str:
        # Prose in `--` comments mentions DDL verbs; only executable SQL counts.
        return "\n".join(
            line.split("--", 1)[0] for line in text.upper().splitlines()
        )

    unguarded: list[str] = []
    for migration in discover_migrations():
        sql = statements_only(migration.read_sql())
        for verb, guard in (
            ("CREATE TABLE ", "CREATE TABLE IF NOT EXISTS"),
            ("CREATE INDEX ", "CREATE INDEX IF NOT EXISTS"),
            ("ADD COLUMN ", "ADD COLUMN IF NOT EXISTS"),
        ):
            if verb in sql and sql.count(verb) != sql.count(guard):
                unguarded.append(f"{migration.filename}: {verb.strip()}")

    assert unguarded == [], f"non-idempotent DDL found: {unguarded}"
