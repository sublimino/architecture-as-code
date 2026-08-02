"""Discovery Portal API health surface for the D2 demo."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from adapters import load_adapter_selections
from api_compat import install_compatibility_api
from onboarding import install_onboarding_api
from db.connection import close_db_pool, get_pool, init_db_pool

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db_pool()
    app.state.adapters = load_adapter_selections()
    yield
    await close_db_pool()


app = FastAPI(title="Signal Loom Discovery Portal", version="0.1.0", lifespan=lifespan)
install_compatibility_api(app)
install_onboarding_api(app)


@app.get("/health")
async def health() -> dict[str, str]:
    """Existing backwards-compatible health endpoint."""
    return {"status": "ok"}


@app.get("/livez")
async def livez() -> dict[str, str]:
    """A process/event-loop probe; it intentionally touches no dependencies."""
    return {"status": "live"}


@app.get("/readyz")
async def readyz(request: Request) -> JSONResponse:
    """PostgreSQL gates readiness; Redis availability is diagnostic only."""
    try:
        await get_pool().fetchval("SELECT 1")
    except Exception:
        logger.exception("discovery portal: PostgreSQL readiness check failed")
        return JSONResponse(status_code=503, content={"status": "not-ready", "postgresql": "unavailable", "redis": "unknown"})

    redis_state = "disabled"
    redis = getattr(request.app.state, "redis", None)
    if redis is not None:
        try:
            await redis.ping()
            redis_state = "ready"
        except Exception:
            logger.warning("discovery portal: Redis degraded", exc_info=True)
            redis_state = "degraded"
    return JSONResponse(content={"status": "ready", "postgresql": "ready", "redis": redis_state})
