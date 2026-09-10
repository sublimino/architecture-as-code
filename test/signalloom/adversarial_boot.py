"""ASGI entrypoint that serves the real Signal Loom app without a database.

Used only by ``test/signalloom/adversarial-boundaries.bats`` (SLON-P3-2).

``main.lifespan`` calls ``init_db_pool()``, which reads ``os.environ["DATABASE_URL"]``
and raises ``KeyError`` when it is absent.  There is deliberately no
"skip migrations" branch in production code -- ``set_pool_for_testing`` is
documented in ``db/connection.py`` as *the* single seam for bypassing the real
database, precisely so that no such branch can ever be taken by accident.

So this module uses that seam and nothing else.  It imports ``main`` unchanged
and re-exports its ``app``; every route, dependency, and exception handler is
the shipped one.  Pointing a fake DSN at ``DATABASE_URL`` instead would make
``asyncpg.create_pool`` attempt a real connection and fail, and pretending the
app boots when it does not is the failure mode this whole card exists to
prevent.

The stub satisfies the one method the lifecycle calls on the pool: ``close()``
at shutdown.  ``init_db_pool`` short-circuits on ``if _pool is None``, so the
migration path is never entered.  ``api_compat._get_pool`` maintains its own
pool independently of this seam and still returns ``None``, so the routes serve
their in-memory fixture branch -- which is all the wire-level probes in that
BATS file need.  Anything requiring a real database lives in the pytest suite,
where a pool fake can be injected per test.

    PYTHONPATH="<src>:<this dir>" uvicorn adversarial_boot:app
"""
from __future__ import annotations

from db.connection import set_pool_for_testing


class _NoDatabase:
    """The minimum surface ``close_db_pool`` touches at shutdown."""

    async def close(self) -> None:
        return None


set_pool_for_testing(_NoDatabase())

from main import app  # noqa: E402  -- must follow the seam call above

__all__ = ["app"]
