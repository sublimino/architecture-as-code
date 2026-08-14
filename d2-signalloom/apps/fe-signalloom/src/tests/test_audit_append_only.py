"""Migration 030 — public.audit_events is append-only.

Two tiers, matching the split the rest of this suite uses.

Tier 1 (always runs, no database) reads the migration and ``db/data-reset.sql``
as text. It exists to stop the guard being quietly weakened: a future edit that
turns the trigger back into a bare ``REVOKE``, drops ``TRUNCATE`` from the event
list, re-enables the trigger as ORIGIN instead of ALWAYS, or strips the
residual-threat comment will fail here rather than in six months.

Tier 2 (needs ``DATABASE_URL``) is the part that actually proves anything. It
connects with the application's own DSN and driver, inserts a real row, and
attempts to rewrite it. An assertion about intent is worthless for a control
like this; the only evidence that counts is a refused statement.

Tier 2 is written as synchronous tests that call ``asyncio.run`` rather than as
``@pytest.mark.asyncio`` coroutines. pytest-asyncio is not installed in every
environment this suite runs in, and a test that silently does not execute is the
exact failure mode an audit-integrity guard cannot afford.

Running Tier 2::

    DATABASE_URL=postgresql://user:pass@host:5432/scratch_db \\
      PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python3 -m pytest -q tests/test_audit_append_only.py

Point it at a scratch database. The fixture applies every migration and one test
runs ``data-reset.sql``, which truncates every governance table.
"""
from __future__ import annotations

import asyncio
import os
import re
from pathlib import Path
from typing import Any

import pytest

from db.migrate import MIGRATIONS_DIR, discover_migrations

MIGRATION_FILE = MIGRATIONS_DIR / "030_audit_events_append_only.sql"
DB_DIR = MIGRATIONS_DIR.parent
DATA_RESET_FILE = DB_DIR / "data-reset.sql"

TRIGGER_NAME = "audit_events_append_only"

# The role the application connects as. Named here so Tier 1 can assert the
# migration does NOT try to REVOKE against it -- see the migration header: that
# role owns the table and is a superuser, so a REVOKE against it is recorded and
# then ignored.
APP_ROLE = "signalloom"


def _executable_sql(text: str) -> str:
    """Strip ``--`` comments. Prose in this migration names every SQL verb."""
    return "\n".join(line.split("--", 1)[0] for line in text.splitlines())


# ---------------------------------------------------------------------------
# Tier 1 -- structure of the migration
# ---------------------------------------------------------------------------

def test_the_migration_is_discovered_by_the_runner() -> None:
    assert MIGRATION_FILE.exists(), f"migration is missing: {MIGRATION_FILE}"
    assert MIGRATION_FILE.name in [m.filename for m in discover_migrations()]


def test_the_guard_is_a_trigger_and_not_a_revoke_against_the_app_role() -> None:
    """The REVOKE-only version of this migration blocks nothing. Keep it gone.

    Measured against the deployed cluster: the app role owns audit_events and
    is a superuser, so ``REVOKE UPDATE ... FROM signalloom`` leaves the ACL
    looking correct while ``UPDATE`` still rewrites every row. A trigger is not
    a privilege check, so superuser does not bypass it.
    """
    sql = _executable_sql(MIGRATION_FILE.read_text(encoding="utf-8"))

    assert re.search(rf"CREATE\s+TRIGGER\s+{TRIGGER_NAME}\b", sql), (
        "the append-only guard must be a trigger"
    )
    assert not re.search(rf"REVOKE\b[^;]*\bFROM\s+{APP_ROLE}\b", sql, re.S), (
        f"a REVOKE against {APP_ROLE} is decoration -- it owns the table and is "
        "a superuser. If this assertion is failing because someone added one "
        "back, read the migration header before deleting this test."
    )
    # Housekeeping for a future non-superuser role, not the control itself.
    assert re.search(r"REVOKE\b[^;]*\bFROM\s+PUBLIC\b", sql, re.S)


def test_the_trigger_covers_update_delete_and_truncate() -> None:
    sql = _executable_sql(MIGRATION_FILE.read_text(encoding="utf-8"))
    create = re.search(
        rf"CREATE\s+TRIGGER\s+{TRIGGER_NAME}\b(.*?);", sql, re.S | re.I,
    )
    assert create is not None
    body = create.group(1).upper()

    assert "BEFORE" in body, "the guard must refuse the statement, not observe it"
    for event in ("UPDATE", "DELETE", "TRUNCATE"):
        assert event in body, (
            f"{event} is not covered. TRUNCATE in particular is the single most "
            "destructive statement against an audit log, and data-reset.sql "
            "reaches audit_events through a CASCADE as well as directly."
        )


def test_the_trigger_is_statement_level() -> None:
    """FOR EACH STATEMENT: no per-row cost, and TRUNCATE cannot be row-level."""
    sql = _executable_sql(MIGRATION_FILE.read_text(encoding="utf-8"))
    create = re.search(
        rf"CREATE\s+TRIGGER\s+{TRIGGER_NAME}\b(.*?);", sql, re.S | re.I,
    )
    assert create is not None
    assert re.search(r"FOR\s+EACH\s+STATEMENT", create.group(1), re.I)


def test_the_trigger_is_enabled_always_not_origin() -> None:
    """``session_replication_role = 'replica'`` skips ORIGIN triggers.

    Setting that GUC requires superuser, which is precisely what the
    application role has, so the ORIGIN default would leave a one-statement
    bypass in place.
    """
    sql = _executable_sql(MIGRATION_FILE.read_text(encoding="utf-8"))
    assert re.search(
        rf"ENABLE\s+ALWAYS\s+TRIGGER\s+{TRIGGER_NAME}\b", sql, re.I,
    ), "the trigger must be ENABLE ALWAYS or replica mode bypasses it"


def test_the_migration_is_idempotent_by_construction() -> None:
    """The runner is the belt to the bootstrap's braces; both must converge."""
    sql = _executable_sql(MIGRATION_FILE.read_text(encoding="utf-8"))
    assert "CREATE OR REPLACE FUNCTION" in sql.upper()
    drop = sql.upper().find(f"DROP TRIGGER IF EXISTS {TRIGGER_NAME}".upper())
    create = sql.upper().find(f"CREATE TRIGGER {TRIGGER_NAME}".upper())
    assert drop != -1, "re-running the migration must not fail on an existing trigger"
    assert drop < create, "the guarded DROP must precede the CREATE"


def test_the_migration_does_not_overclaim() -> None:
    """Naming the residual threats is load-bearing, not decoration.

    A control documented as making the audit log 'immutable' stops people
    asking the next question. This one makes it un-rewritable *by the
    application*, which is a smaller and truthful claim.
    """
    prose = MIGRATION_FILE.read_text(encoding="utf-8").lower()
    for residual in ("superuser", "pg_dump", "disable trigger", "backdat"):
        assert residual in prose, (
            f"the migration no longer documents the residual threat: {residual}"
        )


def test_data_reset_lifts_the_guard_and_puts_it_back() -> None:
    """data-reset.sql is the one sanctioned destructive caller.

    The lift has to wrap the whole body: audit_events.agent_id references
    agent_registry, so ``TRUNCATE public.agent_registry CASCADE`` in the
    'agents' focus fires the trigger too. Guarding only the 'audit' branch
    leaves ``SERVICE=agents`` broken.
    """
    sql = _executable_sql(DATA_RESET_FILE.read_text(encoding="utf-8"))

    disable = sql.upper().find(f"DISABLE TRIGGER {TRIGGER_NAME}".upper())
    enable = sql.upper().find(f"ENABLE ALWAYS TRIGGER {TRIGGER_NAME}".upper())
    assert disable != -1, "data-reset.sql must lift the append-only guard"
    assert enable != -1, "data-reset.sql must restore the guard as ENABLE ALWAYS"

    truncates = [m.start() for m in re.finditer(r"\bTRUNCATE\b", sql, re.I)]
    assert truncates, "data-reset.sql stopped truncating anything"
    assert disable < min(truncates), "the guard is lifted after the first TRUNCATE"
    assert enable > max(truncates), "the guard is restored before the last TRUNCATE"


# ---------------------------------------------------------------------------
# Tier 2 -- refused statements against a live Postgres
# ---------------------------------------------------------------------------

DATABASE_URL = os.environ.get("DATABASE_URL")

live = pytest.mark.skipif(
    DATABASE_URL is None,
    reason="DATABASE_URL not set -- Tier 2 needs a live Postgres",
)

TENANT = "tenant-append-only-test"
EVENT_TYPE = "agent.stunned"


def _run(coro: Any) -> Any:
    """Drive one coroutine to completion.

    Deliberately not ``@pytest.mark.asyncio``: pytest-asyncio is absent in some
    environments this suite runs in, and an unrunnable test proves nothing.
    """
    return asyncio.run(coro)


async def _connect() -> Any:
    import asyncpg

    return await asyncpg.connect(dsn=DATABASE_URL)


async def _apply_all_migrations() -> None:
    conn = await _connect()
    try:
        for migration in discover_migrations():
            await conn.execute(migration.read_sql())
    finally:
        await conn.close()


async def _insert_event(conn: Any) -> str:
    """Insert through the same column list ``_audit_log()`` uses."""
    return await conn.fetchval(
        """INSERT INTO public.audit_events
               (tenant_id, event_type, agent_id, agent_name, actor, detail)
           VALUES ($1, $2, NULL, NULL, 'append-only-test', '{}'::jsonb)
           RETURNING id::text""",
        TENANT, EVENT_TYPE,
    )


async def _refusal(statement: str, *, pre: str | None = None) -> Any:
    """Run ``statement`` against a real row and return the error it raised."""
    import asyncpg

    conn = await _connect()
    try:
        await _insert_event(conn)
        if pre is not None:
            await conn.execute(pre)
        try:
            await conn.execute(statement)
        except asyncpg.PostgresError as error:
            return error
        return None
    finally:
        await conn.close()


def _assert_comprehensible(error: Any, operation: str) -> None:
    assert error is not None, (
        f"{operation} against audit_events was NOT refused -- the append-only "
        "guard is not in force on this database"
    )
    assert error.sqlstate == "42501", (
        f"expected SQLSTATE 42501 (insufficient_privilege), got {error.sqlstate}"
    )
    assert "append-only" in str(error), f"unhelpful error text: {error}"
    assert operation in str(error), f"error does not name the operation: {error}"
    assert "DISABLE TRIGGER" in (getattr(error, "hint", "") or ""), (
        "the error must tell the reader how a sanctioned reset lifts the guard"
    )


@pytest.fixture(scope="module", autouse=True)
def _schema() -> None:
    if DATABASE_URL is None:
        return
    _run(_apply_all_migrations())


@live
def test_inserts_still_work() -> None:
    """The regression bar: every existing audit write must be unaffected."""
    async def go() -> str:
        conn = await _connect()
        try:
            event_id = await _insert_event(conn)
            actor = await conn.fetchval(
                "SELECT actor FROM public.audit_events WHERE id = $1::uuid",
                event_id,
            )
            return actor
        finally:
            await conn.close()

    assert _run(go()) == "append-only-test"


@live
def test_update_is_refused() -> None:
    error = _run(_refusal(
        "UPDATE public.audit_events SET actor = 'TAMPERED'",
    ))
    _assert_comprehensible(error, "UPDATE")


@live
def test_delete_is_refused() -> None:
    error = _run(_refusal("DELETE FROM public.audit_events"))
    _assert_comprehensible(error, "DELETE")


@live
def test_truncate_is_refused() -> None:
    error = _run(_refusal("TRUNCATE public.audit_events"))
    _assert_comprehensible(error, "TRUNCATE")


@live
def test_a_targeted_update_of_one_row_is_refused() -> None:
    """A narrow UPDATE is the realistic shape of tampering, not a bulk one."""
    async def go() -> Any:
        import asyncpg

        conn = await _connect()
        try:
            event_id = await _insert_event(conn)
            try:
                await conn.execute(
                    "UPDATE public.audit_events SET detail = '{\"ok\":true}'::jsonb "
                    "WHERE id = $1::uuid",
                    event_id,
                )
            except asyncpg.PostgresError as error:
                return error
            return None
        finally:
            await conn.close()

    _assert_comprehensible(_run(go()), "UPDATE")


@live
def test_replica_session_role_does_not_bypass_the_guard() -> None:
    """ENABLE ALWAYS is what makes this hold; ORIGIN triggers are skipped here."""
    error = _run(_refusal(
        "DELETE FROM public.audit_events",
        pre="SET session_replication_role = 'replica'",
    ))
    _assert_comprehensible(error, "DELETE")


@live
def test_cascading_truncate_from_agent_registry_is_refused() -> None:
    """audit_events.agent_id references agent_registry, so CASCADE reaches it."""
    error = _run(_refusal("TRUNCATE public.agent_registry CASCADE"))
    _assert_comprehensible(error, "TRUNCATE")


@live
def test_the_guard_does_not_block_ddl_on_the_table() -> None:
    """Two migrations widening event_type are in flight. Do not break them.

    Triggers fire on DML only, so the guarded drop-and-recreate of the CHECK
    constraint that 006, 007, 009, 010 and 011 all use is unaffected. This runs
    that exact shape and then restores the original constraint.
    """
    async def go() -> str:
        conn = await _connect()
        try:
            # Everything below runs in one transaction that is rolled back, so
            # the module leaves the schema exactly as it found it. Rolling back
            # is also the only tidy-up available: a DELETE of the row inserted
            # under the widened vocabulary would itself be refused, which is
            # the guard working as designed.
            transaction = conn.transaction()
            await transaction.start()
            try:
                original = await conn.fetchval(
                    """SELECT pg_get_constraintdef(con.oid)
                         FROM pg_constraint con
                         JOIN pg_class rel ON rel.oid = con.conrelid
                        WHERE rel.relname = 'audit_events'
                          AND con.conname = 'audit_events_event_type_check'""",
                )
                assert original is not None, "event_type CHECK constraint is missing"

                # Derive the vocabulary from the rows actually present rather
                # than splicing pg_get_constraintdef's normalised text, so the
                # recreated constraint validates whatever this module has
                # already inserted and the test does not depend on test order.
                in_use = [
                    row["event_type"]
                    for row in await conn.fetch(
                        "SELECT DISTINCT event_type FROM public.audit_events",
                    )
                ]
                vocabulary = ", ".join(
                    f"'{name}'" for name in sorted({*in_use, "future.newtype"})
                )

                # The exact shape 006/007/009/010/011 use: drop, recreate wider.
                await conn.execute(
                    "ALTER TABLE public.audit_events "
                    "DROP CONSTRAINT audit_events_event_type_check",
                )
                await conn.execute(
                    "ALTER TABLE public.audit_events "
                    "ADD CONSTRAINT audit_events_event_type_check "
                    f"CHECK (event_type IN ({vocabulary}))",
                )
                await conn.execute(
                    """INSERT INTO public.audit_events
                           (tenant_id, event_type, actor, detail)
                       VALUES ($1, 'future.newtype', 'append-only-test',
                               '{}'::jsonb)""",
                    TENANT,
                )
                return await conn.fetchval(
                    """SELECT pg_get_constraintdef(con.oid)
                         FROM pg_constraint con
                         JOIN pg_class rel ON rel.oid = con.conrelid
                        WHERE rel.relname = 'audit_events'
                          AND con.conname = 'audit_events_event_type_check'""",
                )
            finally:
                await transaction.rollback()
        finally:
            await conn.close()

    assert "future.newtype" in _run(go()), (
        "the CHECK-constraint drop-and-recreate that every event_type migration "
        "uses no longer works with the append-only guard installed"
    )


@live
def test_data_reset_still_truncates_audit_events() -> None:
    """The one sanctioned destructive caller must keep working.

    Runs the real ``db/data-reset.sql`` -- the same file
    ``tests/test_contract_tier2.py`` runs after every mutating test and that
    ``make demo-signalloom-data-reset`` invokes.
    """
    async def go() -> int:
        conn = await _connect()
        try:
            await _insert_event(conn)
            before = await conn.fetchval("SELECT count(*) FROM public.audit_events")
            assert before > 0
            await conn.execute(DATA_RESET_FILE.read_text(encoding="utf-8"))
            return await conn.fetchval("SELECT count(*) FROM public.audit_events")
        finally:
            await conn.close()

    assert _run(go()) == 0


@live
def test_the_guard_is_back_in_force_after_a_reset() -> None:
    """data-reset.sql must not leave the table unguarded, or as ORIGIN."""
    async def enabled_flag() -> str:
        conn = await _connect()
        try:
            await conn.execute(DATA_RESET_FILE.read_text(encoding="utf-8"))
            return await conn.fetchval(
                """SELECT trg.tgenabled::text
                     FROM pg_trigger trg
                     JOIN pg_class rel ON rel.oid = trg.tgrelid
                    WHERE rel.relname = 'audit_events' AND trg.tgname = $1""",
                TRIGGER_NAME,
            )
        finally:
            await conn.close()

    # 'A' = ENABLE ALWAYS, 'O' = ENABLE (origin), 'D' = DISABLED.
    assert _run(enabled_flag()) == "A"

    error = _run(_refusal("DELETE FROM public.audit_events"))
    _assert_comprehensible(error, "DELETE")
