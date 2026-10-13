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
from fastapi.responses import JSONResponse, Response

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
) -> Response:
    """Forward a request to the signal-ingest coding agent telemetry service."""
    req_headers = headers or {}
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(
                method, path, headers=req_headers, content=content, params=params
            )
            if resp.status_code in (204, 205, 304) or not resp.content or method == "HEAD":
                body = None
            else:
                try:
                    body = resp.json()
                except Exception:
                    body = {"raw": resp.text}
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
    except httpx.RemoteProtocolError as exc:
        logger.warning("signal-ingest closed the connection: %s %s", method, path)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest closed the connection without a response (restarting?)"
        ) from exc
    except APIError:
        raise
    except Exception as exc:
        logger.exception("signal-ingest proxy error: %s %s", method, path)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest proxy error"
        ) from exc

    # Forward headers per RFC 9110
    from collections.abc import Mapping

    forwarded_headers: dict[str, str] = {}
    resp_headers_map: dict[str, str] = {}
    headers_obj = getattr(resp, "headers", None)
    if isinstance(headers_obj, Mapping):
        resp_headers_map = {str(k).lower(): str(v) for k, v in headers_obj.items()}
    for header_key in ("allow", "etag", "location", "x-tenant-id", "retry-after", "x-request-id"):
        if header_key in resp_headers_map:
            forwarded_headers[header_key] = resp_headers_map[header_key]

    if resp.status_code in (204, 205, 304) or method == "HEAD" or body is None:
        if "content-type" in resp_headers_map and resp.status_code not in (204, 205, 304):
            forwarded_headers["content-type"] = resp_headers_map["content-type"]
        return Response(status_code=resp.status_code, content=b"", headers=forwarded_headers)

    return JSONResponse(status_code=resp.status_code, content=body, headers=forwarded_headers)


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
) -> Response:
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
) -> Response:
    """List stored coding agent telemetry records for the authenticated tenant."""
    headers = _telemetry_headers(principal, False)
    params = dict(request.query_params)
    method = request.method if request and getattr(request, "method", None) else "GET"
    return await _proxy_telemetry(
        method, "/api/v1/telemetry/coding-agents", headers=headers, params=params
    )


@router.get("/aggregate")
async def get_coding_agent_aggregate(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Response:
    """Get k-anonymity (k=5) protected aggregate metrics for coding agents."""
    headers = _telemetry_headers(principal, False)
    params = dict(request.query_params)
    method = request.method if request and getattr(request, "method", None) else "GET"
    return await _proxy_telemetry(
        method, "/api/v1/telemetry/coding-agents/aggregate", headers=headers, params=params
    )


@router.post("/ordering")
async def evaluate_coding_agent_ordering(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Response:
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
