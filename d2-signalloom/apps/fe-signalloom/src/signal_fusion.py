"""Signal Fusion API routes.

Proxies signal fusion requests to the Go signal-ingest service.
The Go service owns the signal store; this module provides the
dashboard-facing API surface alongside the existing platform routes.
"""
from __future__ import annotations

import logging
import os
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from api_compat import APIError, Principal, authenticated_principal, authenticated_tenant

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/signals", tags=["signal-fusion"])

_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 10.0


async def _proxy(method: str, path: str, **kwargs: Any) -> JSONResponse:
    """Forward a request to the signal-ingest service."""
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(method, path, **kwargs)
            return JSONResponse(status_code=resp.status_code, content=resp.json())
    except httpx.ConnectError as exc:
        logger.warning("signal-ingest service unreachable at %s", _SIGNAL_INGEST_URL)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest service unreachable"
        ) from exc
    except httpx.TimeoutException as exc:
        logger.warning("signal-ingest request timed out: %s %s", method, path)
        raise APIError(
            504, "upstream_timeout", "signal-ingest request timed out"
        ) from exc
    except Exception as exc:
        logger.exception("signal-ingest proxy error: %s %s", method, path)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest proxy error"
        ) from exc


@router.get("/observations")
async def get_observations(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
    layer: str | None = None,
    limit: int = Query(default=100, ge=1, le=1000),
) -> JSONResponse:
    """List signal observations from the columnar store."""
    params: dict[str, Any] = {"limit": limit}
    if layer:
        params["layer"] = layer
    return await _proxy("GET", "/api/v1/observations", params=params)


@router.get("/actors")
async def get_actors(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> JSONResponse:
    """List provisional actors."""
    return await _proxy("GET", "/api/v1/actors")


@router.get("/actors/{actor_id}")
async def get_actor(
    actor_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> JSONResponse:
    """Get a single provisional actor with evidence chain."""
    return await _proxy("GET", f"/api/v1/actors/{actor_id}")


@router.post("/actors/{actor_id}/promote")
async def promote_actor(
    actor_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Promote a provisional actor to the agent registry."""
    return await _proxy("POST", f"/api/v1/actors/{actor_id}/promote")


@router.get("/coverage")
async def get_coverage(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> JSONResponse:
    """Get signal coverage across observation layers."""
    return await _proxy("GET", "/api/v1/coverage")


@router.post("/correlate")
async def run_correlation(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Trigger a correlation engine run."""
    return await _proxy("POST", "/api/v1/correlate")


@router.get("/store/stats")
async def get_store_stats(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> JSONResponse:
    """Get store diagnostics — observation counts, actor stats, store type."""
    return await _proxy("GET", "/api/v1/store/stats")


@router.post("/collectors/seed")
async def seed_collectors(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Seed the signal collectors with initial data."""
    return await _proxy("POST", "/api/v1/collectors/seed")


def install_signal_fusion_api(app: Any) -> None:
    """Mount the signal fusion router on the FastAPI app."""
    app.include_router(router)
