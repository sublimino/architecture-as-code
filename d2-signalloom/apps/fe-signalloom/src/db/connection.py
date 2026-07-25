"""Small database-pool seam used by application startup and readiness."""
from typing import Any

_pool: Any | None = None


async def init_db_pool() -> None:
    """Initialise the pool in the full portal runtime.

    Packaging this task keeps the initialization seam deliberately injectable; the
    deployment task supplies the concrete asyncpg pool construction.
    """


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
