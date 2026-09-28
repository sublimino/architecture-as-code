#!/usr/bin/env python3
"""SLRC-P2-2 migration probe: apply the full chain to an empty scratch database.

Proves migration 043_eap_environment_lifecycle.sql applies cleanly through
``db.migrate.apply_migrations`` and that a second apply is a no-op. Run from
``d2-signalloom/apps/fe-signalloom/src`` with DATABASE_URL pointing at an
isolated server whose role has CREATEDB. The scratch database is always dropped.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

sys.path.insert(0, os.getcwd())

import asyncpg  # noqa: E402

from db.migrate import apply_migrations, discover_migrations  # noqa: E402

TARGET = "043_eap_environment_lifecycle.sql"
TABLES = ("eap_environment_lifecycle", "eap_lifecycle_outbox")


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


async def probe(dsn: str) -> dict:
    name = f"slrc_p22_migration_{uuid.uuid4().hex[:12]}"
    admin = await asyncpg.connect(dsn, timeout=10)
    server_version = await admin.fetchval("SHOW server_version")
    await admin.execute(f'CREATE DATABASE "{name}"')
    await admin.close()
    try:
        pool = await asyncpg.create_pool(_with_database(dsn, name), min_size=1, max_size=2)
        try:
            empty = await pool.fetchval(
                "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
            )
            started = time.perf_counter()
            first = await apply_migrations(pool)
            first_seconds = time.perf_counter() - started
            second = await apply_migrations(pool)
            recorded = await pool.fetchval(
                "SELECT count(*) FROM public.schema_migrations WHERE filename=$1", TARGET
            )
            tables = {
                table: await pool.fetchval(
                    "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name=$1",
                    table,
                )
                for table in TABLES
            }
            constraints = [
                record["conname"] for record in await pool.fetch(
                    """SELECT conname FROM pg_constraint
                       WHERE conrelid IN ('public.eap_environment_lifecycle'::regclass,
                                          'public.eap_lifecycle_outbox'::regclass)
                       ORDER BY conname"""
                )
            ]
        finally:
            await pool.close()
    finally:
        admin = await asyncpg.connect(dsn, timeout=10)
        await admin.execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$1", name
        )
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}"')
        await admin.close()

    available = [migration.filename for migration in discover_migrations()]
    result = {
        "server_version": server_version,
        "scratch_database": name,
        "scratch_database_dropped": True,
        "public_tables_before": empty,
        "migrations_available": len(available),
        "first_apply_count": len(first),
        "first_apply_seconds": round(first_seconds, 3),
        "first_apply_includes_043": TARGET in first,
        "first_apply_last": first[-1] if first else None,
        "second_apply": second,
        "second_apply_is_noop": second == [],
        "043_recorded_in_schema_migrations": recorded == 1,
        "lifecycle_table_column_counts": tables,
        "lifecycle_constraints": constraints,
    }
    result["ok"] = bool(
        empty == 0 and result["first_apply_includes_043"] and result["second_apply_is_noop"]
        and result["043_recorded_in_schema_migrations"] and all(tables.values())
        and len(first) == len(available)
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        print("DATABASE_URL is required", file=sys.stderr)
        return 2
    result = asyncio.run(probe(dsn))
    args.out.write_text(json.dumps(result, indent=2, default=str) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("ok", "first_apply_count", "first_apply_includes_043",
                                             "second_apply_is_noop", "server_version")}))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
