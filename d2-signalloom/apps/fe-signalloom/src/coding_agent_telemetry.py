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

from api_compat import APIError, Principal, authenticated_principal
from ingest_client import ingest_headers

logger = logging.getLogger(__name__)

router = APIRouter(tags=["coding-agent-telemetry"])

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


# Telemetry is per-tenant data with no cross-tenant view, so every route acts for the caller's own
# tenant (write=True), superadmin included. The caller's own Authorization is no longer forwarded:
# signal-ingest never accepted a dashboard token, so the forward only ever produced 401s.


def _telemetry_headers(principal: Principal, content_type: bool, contract: str | None = None) -> dict[str, str]:
    headers = ingest_headers(principal, write=True)
    if content_type:
        headers["Content-Type"] = "application/json"
    if contract:
        headers["X-SignalLoom-Contract"] = contract
    return headers


@router.post("")
async def ingest_coding_agent_telemetry(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    x_signalloom_contract: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    """Ingest CodingAgentTelemetry event, validating closed-world schema and isolating by tenant."""
    headers = _telemetry_headers(principal, True, x_signalloom_contract)
    body = await request.body()
    return await _proxy_telemetry(
        "POST", "/api/v1/telemetry/coding-agents", headers=headers, content=body
    )


@router.get("")
async def list_coding_agent_telemetry(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """List stored coding agent telemetry records for the authenticated tenant."""
    headers = _telemetry_headers(principal, False)
    params = dict(request.query_params)
    return await _proxy_telemetry(
        "GET", "/api/v1/telemetry/coding-agents", headers=headers, params=params
    )


@router.get("/aggregate")
async def get_coding_agent_aggregate(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Get k-anonymity (k=5) protected aggregate metrics for coding agents."""
    headers = _telemetry_headers(principal, False)
    params = dict(request.query_params)
    return await _proxy_telemetry(
        "GET", "/api/v1/telemetry/coding-agents/aggregate", headers=headers, params=params
    )


@router.post("/ordering")
async def evaluate_coding_agent_ordering(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Evaluate cross-workstation causal ordering with clock-skew bounds."""
    headers = _telemetry_headers(principal, True)
    body = await request.body()
    return await _proxy_telemetry(
        "POST", "/api/v1/telemetry/coding-agents/ordering", headers=headers, content=body
    )


def install_coding_agent_telemetry_api(app: Any) -> None:
    """Mount the coding agent telemetry router on the FastAPI app."""
    app.include_router(router, prefix="/api/v1/telemetry/coding-agents")
    app.include_router(router, prefix="/v1/telemetry/coding-agents")
