"""Quantitative Risk (OpenFAIR) API routes.

Proxies OpenFAIR risk queries to the Go signal-ingest service, which owns
the canonical OpenFAIR risk engine (pkg/fair).
"""
from __future__ import annotations

import logging
import os
from typing import Any

import httpx
from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse

from api_compat import APIError

logger = logging.getLogger(__name__)

router = APIRouter(tags=["risk"])

_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 10.0


async def _proxy(method: str, path: str, **kwargs: Any) -> JSONResponse:
    """Forward a request to the signal-ingest service."""
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(method, path, **kwargs)
            try:
                content = resp.json()
            except Exception:
                content = {"raw": resp.text}
            return JSONResponse(status_code=resp.status_code, content=content)
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


@router.get("/api/v1/risk/agents/{agent_id:path}")
@router.get("/v1/risk/agents/{agent_id:path}")
async def get_agent_risk(
    agent_id: str,
    request: Request,
    trials: int | None = Query(default=None),
    seed: int | None = Query(default=None),
    model: str | None = Query(default=None),
) -> JSONResponse:
    """Get quantitative OpenFAIR risk assessment for a specific agent."""
    params: dict[str, Any] = {}
    if trials is not None:
        params["trials"] = trials
    if seed is not None:
        params["seed"] = seed
    if model is not None:
        params["model"] = model
    return await _proxy("GET", f"/api/v1/risk/agents/{agent_id}", params=params)


@router.get("/api/v1/risk/fleet")
@router.get("/v1/risk/fleet")
async def get_fleet_risk(
    request: Request,
) -> JSONResponse:
    """Get quantitative OpenFAIR risk rollup across the agent fleet."""
    return await _proxy("GET", "/api/v1/risk/fleet")


def install_risk_api(app: Any) -> None:
    """Mount the risk API router on the FastAPI app."""
    app.include_router(router)
