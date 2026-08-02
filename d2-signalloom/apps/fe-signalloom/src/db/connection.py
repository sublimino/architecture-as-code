"""Small database-pool seam used by application startup and readiness."""
import os
from typing import Any

import asyncpg

from db.migrate import apply_migrations

_pool: Any | None = None


async def init_db_pool() -> None:
    """Initialise the PostgreSQL pool once, and bring the schema up to date.

    Opening the pool and migrating are one lifecycle concern: serving traffic on
    a pool whose schema is stale is what produced the
    ``UndefinedColumnError``/500 this runner exists to prevent.  Keeping the two
    together also means ``set_pool_for_testing`` remains the single documented
    seam for bypassing the real database -- tests that inject a pool skip the
    migration for free, and production has no "skip migrations" branch that
    could ever be taken by accident.

    A migration failure propagates: the pool is closed and the exception reaches
    the FastAPI lifespan, so the process refuses to start rather than serving
    against a half-migrated schema.
    """
    global _pool
    if _pool is None:
        pool = await asyncpg.create_pool(dsn=os.environ["DATABASE_URL"])
        try:
            await apply_migrations(pool)
        except BaseException:
            await pool.close()
            raise
        _pool = pool


async def close_db_pool() -> None:
    global _pool
    pool, _pool = _pool, None
    if pool is not None:
        await pool.close()


def get_pool() -> Any:
    if _pool is None:
        raise RuntimeError("Database pool not initialised")
    return _pool


def set_pool_for_testing(pool: Any | None) -> None:
    """Set the pool for focused readiness tests only."""
    global _pool
    _pool = pool
