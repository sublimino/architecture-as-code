"""Federated Services reverse proxy routes for fe-signalloom.

Proxies /api/v1/federation/* and /v1/federation/* requests to the Go signal-ingest
service (http://signal-ingest:8082).
Injects authenticated tenant ID, preserves inbound SPIFFE SVID credentials,
validates inbound JSON payloads, and handles upstream connection failures with
structured HTTP 502/504 errors instead of HTML fallbacks.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse

from api_compat import (
    APIError,
    Principal,
    _error_response,
    authenticated_principal,
    authenticated_tenant,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["federation"])

SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = float(os.getenv("FEDERATION_PROXY_TIMEOUT", "10.0"))


async def proxy_federation_request(
    request: Request,
    subpath: str = "",
    tenant_id: str | None = None,
) -> Response:
    """Forward a request to the signal-ingest federation endpoints with tenant isolation."""
    clean_subpath = subpath.lstrip("/")
    target_path = f"/api/v1/federation/{clean_subpath}" if clean_subpath else "/api/v1/federation"

    # Inbound content-type and body validation for mutating methods
    body_bytes: bytes | None = None
    if request.method in ("POST", "PUT", "PATCH"):
        raw_body = await request.body()
        if raw_body:
            content_type = request.headers.get("content-type", "")
            if not content_type.lower().startswith("application/json"):
                logger.warning(
                    "federation proxy rejected request with non-JSON Content-Type: %r",
                    content_type,
                )
                return _error_response(
                    400,
                    "invalid_content_type",
                    "Content-Type must be application/json",
                )
            try:
                json.loads(raw_body)
            except Exception as exc:
                logger.warning("federation proxy rejected malformed JSON body: %s", exc)
                return _error_response(
                    400,
                    "invalid_json",
                    f"Malformed JSON request body: {exc}",
                )
            body_bytes = raw_body

    headers: dict[str, str] = {
        "Accept": "application/json",
    }
    if body_bytes is not None:
        headers["Content-Type"] = "application/json"
    if tenant_id:
        headers["X-Tenant-ID"] = tenant_id

    # Preserve SPIFFE SVID credential headers and Authorization
    for k, v in request.headers.items():
        k_lower = k.lower()
        if k_lower == "x-spiffe-svid":
            headers["X-SPIFFE-SVID"] = v
        elif k_lower.startswith("x-") and k_lower not in ("x-tenant-id", "host"):
            headers[k] = v

    auth_header = request.headers.get("authorization")
    if auth_header:
        headers["Authorization"] = auth_header

    params = dict(request.query_params)
    if tenant_id and "tenant" not in params:
        params["tenant"] = tenant_id

    try:
        async with httpx.AsyncClient(
            base_url=SIGNAL_INGEST_URL,
            timeout=_TIMEOUT,
        ) as client:
            resp = await client.request(
                method=request.method,
                url=target_path,
                params=params,
                content=body_bytes,
                headers=headers,
            )
    except httpx.ConnectError as exc:
        logger.warning(
            "signal-ingest federation service unreachable at %s: %s",
            SIGNAL_INGEST_URL,
            exc,
        )
        return _error_response(
            502,
            "upstream_unavailable",
            f"signal-ingest service unreachable at {SIGNAL_INGEST_URL}",
        )
    except httpx.TimeoutException as exc:
        logger.warning(
            "signal-ingest federation request timed out: %s %s",
            request.method,
            target_path,
        )
        return _error_response(
            504,
            "upstream_timeout",
            "signal-ingest federation request timed out",
        )
    except Exception as exc:
        logger.exception(
            "signal-ingest federation proxy error: %s %s (%s)",
            request.method,
            target_path,
            exc,
        )
        return _error_response(
            502,
            "upstream_error",
            f"signal-ingest proxy error: {exc}",
        )

    # Outbound content-type validation: reject HTML fallbacks or non-JSON payloads
    resp_content_type = resp.headers.get("content-type", "")
    resp_text_sample = resp.text[:100].lower() if resp.text else ""
    if (
        "text/html" in resp_content_type.lower()
        or "<!doctype" in resp_text_sample
        or "<html" in resp_text_sample
    ):
        logger.warning(
            "signal-ingest returned HTML instead of JSON: status=%d content_type=%r",
            resp.status_code,
            resp_content_type,
        )
        return _error_response(
            502,
            "invalid_upstream_response",
            f"signal-ingest returned non-JSON response (status {resp.status_code})",
        )

    try:
        data = resp.json()
    except Exception as exc:
        logger.warning(
            "signal-ingest returned unparseable JSON: status=%d error=%s",
            resp.status_code,
            exc,
        )
        return _error_response(
            502,
            "invalid_upstream_response",
            f"signal-ingest returned unparseable JSON (status {resp.status_code})",
        )

    return JSONResponse(
        status_code=resp.status_code,
        content=data,
        headers={"Content-Type": "application/json"},
    )


# ---------------------------------------------------------------------------
# Federation Routes (/api/v1/federation/* and /v1/federation/*)
# ---------------------------------------------------------------------------


@router.api_route(
    "/api/v1/federation/{subpath:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
)
@router.api_route(
    "/api/v1/federation",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
)
@router.api_route(
    "/v1/federation/{subpath:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
)
@router.api_route(
    "/v1/federation",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
)
async def proxy_federation_route(
    request: Request,
    subpath: str = "",
    tenant_id: str = Depends(authenticated_tenant),
) -> Response:
    """Proxy federation requests to upstream signal-ingest service with tenant isolation."""
    return await proxy_federation_request(request, subpath, tenant_id=tenant_id)


def install_federation_api(app: Any) -> None:
    """Mount the federation reverse proxy router on the FastAPI app."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is proxy_federation_route:
            return
    app.include_router(router)
