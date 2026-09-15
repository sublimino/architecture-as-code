"""Coding Agent Telemetry BFF API routes (SLCD-P5-1).

Proxies coding agent telemetry ingestion, query, and aggregate analysis
requests from dashboard clients and detective sensors to the Go signal-ingest service.
"""
from __future__ import annotations

import logging
import os
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Header, Request
from fastapi.responses import JSONResponse

from api_compat import APIError, Principal, authenticated_principal, authenticated_tenant

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/telemetry/coding-agents", tags=["coding-agent-telemetry"])

_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 10.0


async def _proxy_telemetry(
    method: str,
    path: str,
    headers: dict[str, str] | None = None,
    content: bytes | None = None,
    params: dict[str, Any] | None = None,
) -> JSONResponse:
    """Forward a request to the signal-ingest coding agent telemetry service."""
    req_headers = headers or {}
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(
                method, path, headers=req_headers, content=content, params=params
            )
            try:
                body = resp.json()
            except Exception:
                body = {"raw": resp.text}
            return JSONResponse(status_code=resp.status_code, content=body)
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


@router.post("")
async def ingest_coding_agent_telemetry(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
    x_signalloom_contract: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    """Ingest CodingAgentTelemetry event, validating closed-world schema and isolating by tenant."""
    body = await request.body()
    forward_headers: dict[str, str] = {"Content-Type": "application/json"}
    if authorization:
        forward_headers["Authorization"] = authorization
    if x_signalloom_contract:
        forward_headers["X-SignalLoom-Contract"] = x_signalloom_contract

    return await _proxy_telemetry(
        "POST", "/api/v1/telemetry/coding-agents", headers=forward_headers, content=body
    )


@router.get("")
async def list_coding_agent_telemetry(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    """List stored coding agent telemetry records for the authenticated tenant."""
    forward_headers: dict[str, str] = {}
    if authorization:
        forward_headers["Authorization"] = authorization

    params = dict(request.query_params)
    return await _proxy_telemetry(
        "GET", "/api/v1/telemetry/coding-agents", headers=forward_headers, params=params
    )


@router.get("/aggregate")
async def get_coding_agent_aggregate(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    """Get k-anonymity (k=5) protected aggregate metrics for coding agents."""
    forward_headers: dict[str, str] = {}
    if authorization:
        forward_headers["Authorization"] = authorization

    params = dict(request.query_params)
    return await _proxy_telemetry(
        "GET", "/api/v1/telemetry/coding-agents/aggregate", headers=forward_headers, params=params
    )


@router.post("/ordering")
async def evaluate_coding_agent_ordering(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    """Evaluate cross-workstation causal ordering with clock-skew bounds."""
    body = await request.body()
    forward_headers: dict[str, str] = {"Content-Type": "application/json"}
    if authorization:
        forward_headers["Authorization"] = authorization

    return await _proxy_telemetry(
        "POST", "/api/v1/telemetry/coding-agents/ordering", headers=forward_headers, content=body
    )


def install_coding_agent_telemetry_api(app: Any) -> None:
    """Mount the coding agent telemetry router on the FastAPI app."""
    app.include_router(router)
