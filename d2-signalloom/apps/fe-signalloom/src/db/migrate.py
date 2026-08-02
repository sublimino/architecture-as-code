"""Forward-only schema migration runner for the Discovery Portal database.

Why this exists
---------------
``src/db/migrations/*.sql`` used to reach Postgres by exactly one route: the
generated bootstrap SQL, mounted into ``/docker-entrypoint-initdb.d``.  Postgres
runs that directory once, when the data directory is empty.  Every database that
had already been provisioned therefore silently missed every migration added
afterwards -- the API would start cleanly and then fail at query time with
``UndefinedColumnError``.  Fresh clusters worked; existing demos broke.

This runner closes that gap.  It is the belt to the bootstrap's braces: on a
fresh database the bootstrap has already created everything and each migration
is a no-op, and on an existing database the runner applies whatever is missing.
The two must never disagree, which is why every migration is written to be
idempotent (``CREATE ... IF NOT EXISTS``, ``ADD COLUMN IF NOT EXISTS``, guarded
``DO`` blocks).

Concurrency
-----------
Several API replicas can start at once.  ``IF NOT EXISTS`` alone is not enough:
concurrent ``CREATE TABLE IF NOT EXISTS`` still races on ``pg_type`` and raises
``DuplicateObjectError``, and a future migration may legitimately contain
non-idempotent DML.  So the whole apply is serialised behind a session-level
``pg_advisory_lock``.  The second replica blocks, then finds every version
already recorded and does nothing.

Failure
-------
A failing migration raises :class:`MigrationError` out of startup.  Nothing here
swallows an error and carries on: a process serving traffic against a
half-migrated schema is the exact failure mode this module exists to remove.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

MIGRATIONS_DIR = Path(__file__).resolve().parent / "migrations"

# Same grammar the bootstrap generator enforces
# (infra/inf-signalloom/scripts/generate-bootstrap.py), so a filename that one
# accepts is a filename the other accepts.
MIGRATION_FILENAME = re.compile(r"^(?P<version>[0-9]+)_(?P<name>[a-z0-9][a-z0-9_-]*)\.sql$")

# Arbitrary but stable 64-bit key. Every process that migrates this database
# must use this value or the lock buys nothing. ASCII "SGNLMIGR".
ADVISORY_LOCK_KEY = 0x53474E4C4D494752

SCHEMA_MIGRATIONS_DDL = """
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version    TEXT        PRIMARY KEY,
    filename   TEXT        NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""


class MigrationError(RuntimeError):
    """A migration file could not be applied. Startup must not continue."""


@dataclass(frozen=True)
class Migration:
    version: str
    filename: str
    path: Path

    @property
    def sort_key(self) -> tuple[int, str]:
        return int(self.version), self.filename

    def read_sql(self) -> str:
        return self.path.read_text(encoding="utf-8")


def discover_migrations(directory: Path = MIGRATIONS_DIR) -> list[Migration]:
    """Return every migration in the directory, ordered by version.

    Raises ``MigrationError`` on an unparseable filename or a duplicated
    version, rather than guessing at an order.
    """
    if not directory.is_dir():
        raise MigrationError(f"migrations directory not found: {directory}")

    found: dict[str, Migration] = {}
    for path in sorted(directory.iterdir()):
        if not path.is_file() or path.suffix != ".sql":
            continue
        match = MIGRATION_FILENAME.fullmatch(path.name)
        if match is None:
            raise MigrationError(f"ambiguous migration filename: {path.name}")
        version = str(int(match["version"]))
        if version in found:
            raise MigrationError(
                f"duplicate migration version {version}: "
                f"{found[version].filename}, {path.name}",
            )
        found[version] = Migration(version=version, filename=path.name, path=path)

    if not found:
        raise MigrationError(f"no migrations found in {directory}")
    return sorted(found.values(), key=lambda migration: migration.sort_key)


async def apply_migrations(pool: Any, directory: Path = MIGRATIONS_DIR) -> list[str]:
    """Apply every not-yet-recorded migration. Returns the filenames applied."""
    migrations = discover_migrations(directory)

    applied: list[str] = []
    async with pool.acquire() as conn:
        # Lock first: creating the ledger is itself a racy DDL statement.
        await conn.execute("SELECT pg_advisory_lock($1)", ADVISORY_LOCK_KEY)
        try:
            await conn.execute(SCHEMA_MIGRATIONS_DDL)
            recorded = {
                row["version"]
                for row in await conn.fetch("SELECT version FROM public.schema_migrations")
            }
            for migration in migrations:
                if migration.version in recorded:
                    continue
                logger.info("applying database migration %s", migration.filename)
                try:
                    # No arguments: asyncpg uses the simple query protocol, which
                    # is what lets a migration file contain several statements
                    # and its own BEGIN/COMMIT.
                    await conn.execute(migration.read_sql())
                except Exception as exc:
                    logger.error(
                        "database migration %s failed: %s", migration.filename, exc,
                    )
                    raise MigrationError(
                        f"migration {migration.filename} failed: {exc}",
                    ) from exc
                await conn.execute(
                    """INSERT INTO public.schema_migrations (version, filename)
                       VALUES ($1, $2)
                       ON CONFLICT (version) DO NOTHING""",
                    migration.version, migration.filename,
                )
                applied.append(migration.filename)
        finally:
            await conn.execute("SELECT pg_advisory_unlock($1)", ADVISORY_LOCK_KEY)

    if applied:
        logger.info(
            "applied %d database migration(s): %s", len(applied), ", ".join(applied),
        )
    else:
        logger.info(
            "database schema is up to date (%d migration(s) known)", len(migrations),
        )
    return applied
