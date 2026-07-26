"""Small database-pool seam used by application startup and readiness."""
import os
from typing import Any

import asyncpg

_pool: Any | None = None


async def init_db_pool() -> None:
    """Initialise the PostgreSQL pool once for the portal runtime."""
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(dsn=os.environ["DATABASE_URL"])


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
