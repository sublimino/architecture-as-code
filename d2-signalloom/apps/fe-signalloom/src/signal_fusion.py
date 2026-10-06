"""Signal Fusion API routes.

Proxies signal fusion requests to the Go signal-ingest service.
The Go service owns the signal store; this module provides the
dashboard-facing API surface alongside the existing platform routes.
"""
from __future__ import annotations

import logging
import os
import urllib.parse
from collections.abc import AsyncIterator
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse, StreamingResponse

from api_compat import APIError, Principal, _audit_outbound_request, authenticated_principal
from cross_tenant_audit import audit_cross_tenant_read
from ingest_client import ingest_headers
from superadmin import require_superadmin

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/signals", tags=["signal-fusion"])

_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = 10.0


async def _proxy(method: str, path: str, principal: Principal, *, write: bool = False, **kwargs: Any) -> JSONResponse:
    """Forward a request to signal-ingest as the gateway, acting for ``principal``'s tenant.

    The headers are built before the request so a missing gateway key is its own 503, never
    folded into the generic 502 below and never sent as an anonymous request.
    """
    headers = ingest_headers(principal, write=write)
    try:
        async with httpx.AsyncClient(
            base_url=_SIGNAL_INGEST_URL, timeout=_TIMEOUT
        ) as client:
            resp = await client.request(method, path, headers=headers, **kwargs)
            content = resp.json()
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
        # The pod died mid-request (OOM-killed, restarting); not a proxy bug.
        logger.warning("signal-ingest closed the connection: %s %s", method, path)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest closed the connection without a response (restarting?)"
        ) from exc
    except Exception as exc:
        logger.exception("signal-ingest proxy error: %s %s", method, path)
        raise APIError(
            502, "upstream_unavailable", "signal-ingest proxy error"
        ) from exc

    if not write and 200 <= resp.status_code < 300:
        # Gated on `write`, not just the response: a write always acts for the caller's own
        # tenant (ingest_client.acting_tenant), so this is a no-op for one, but gating it
        # explicitly keeps the intent legible rather than relying on that always being true.
        # Raises 503 database_unavailable (fail closed) if a superadmin's read just surfaced
        # another tenant's data and the audit database is unreachable -- see cross_tenant_audit.py.
        await audit_cross_tenant_read(
            principal, f"{method} {path}", content, what=f"Reading {path} cross-tenant",
        )
    return JSONResponse(status_code=resp.status_code, content=content)


@router.get("/observations")
async def get_observations(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    layer: str | None = None,
    limit: int = Query(default=100, ge=1, le=1000),
) -> JSONResponse:
    """List signal observations from the columnar store."""
    params: dict[str, Any] = {"limit": limit}
    if layer:
        params["layer"] = layer
    return await _proxy("GET", "/api/v1/observations", principal, params=params)



@router.get("/observations/stream")
async def stream_observations(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    after: str | None = None,
    before: str | None = None,
    layers: str | None = None,
    actor_id: str | None = None,
    limit: int = Query(default=100, ge=1, le=1000),
) -> StreamingResponse:
    """Stream signal observations as Server-Sent Events."""
    params: dict[str, Any] = {"limit": limit}
    if after:
        params["after"] = after
    if before:
        params["before"] = before
    if layers:
        params["layers"] = layers
    if actor_id:
        params["actor_id"] = actor_id

    headers = ingest_headers(principal)

    # One event per stream open, not per item: the stream has no end and no complete body to
    # scan the way every other proxied route's response does, so there is nothing to extract a
    # real tenant_id from -- but a superadmin opening a cross-tenant-capable stream must still
    # never go unrecorded (Andy's review, 2026-10-06). The sentinel "stream" tenant and the
    # filter parameters the caller asked for stand in for the (unbounded, future) set of
    # tenants the stream may yield. Raises 503 database_unavailable (fail closed) before the
    # stream opens if the audit write itself cannot be recorded.
    await audit_cross_tenant_read(
        principal, "GET /api/v1/observations/stream", [{"tenant_id": "stream"}],
        what="Opening observations stream cross-tenant",
        extra={"filters": {"after": after, "before": before, "layers": layers, "actor_id": actor_id, "limit": limit}},
    )

    async def event_generator() -> AsyncIterator[bytes]:
        try:
            async with httpx.AsyncClient(
                base_url=_SIGNAL_INGEST_URL, timeout=None
            ) as client:
                async with client.stream(
                    "GET", "/api/v1/observations/stream", params=params, headers=headers
                ) as resp:
                    resp.raise_for_status()
                    async for chunk in resp.aiter_bytes():
                        yield chunk
        except httpx.ConnectError as exc:
            logger.warning("signal-ingest service unreachable at %s", _SIGNAL_INGEST_URL)
            yield b"event: error\ndata: {\"error\": \"upstream_unavailable\"}\n\n"
        except httpx.TimeoutException as exc:
            logger.warning("signal-ingest stream timed out")
            yield b"event: error\ndata: {\"error\": \"upstream_timeout\"}\n\n"
        except Exception as exc:
            logger.exception("signal-ingest stream proxy error")
            yield b"event: error\ndata: {\"error\": \"upstream_error\"}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        },
    )


@router.get("/actors")
async def get_actors(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """List provisional actors."""
    return await _proxy("GET", "/api/v1/actors", principal)


@router.get("/actors/{actor_id}")
async def get_actor(
    actor_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Get a single provisional actor with evidence chain."""
    quoted = urllib.parse.quote(actor_id, safe="")
    return await _proxy("GET", f"/api/v1/actors/{quoted}", principal)


@router.get("/actors/{actor_id}/authorization")
async def get_actor_authorization(
    actor_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    action: str | None = None,
) -> JSONResponse:
    """Get authorization chain for an actor."""
    params: dict[str, Any] = {}
    if action:
        params["action"] = action
    quoted = urllib.parse.quote(actor_id, safe="")
    return await _proxy("GET", f"/api/v1/actors/{quoted}/authorization", principal, params=params)


@router.get("/authorization")
async def query_authorization(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    actor_id: str | None = None,
    action: str | None = None,
) -> JSONResponse:
    """Query authorization chains estate-wide or filtered."""
    params: dict[str, Any] = {}
    if actor_id:
        params["actor_id"] = actor_id
    if action:
        params["action"] = action
    return await _proxy("GET", "/api/v1/authorization", principal, params=params)


#: Event type admitted by migration 055.
EVENT_ACTOR_PROMOTE = "actor.promote_requested"


@router.post("/actors/{actor_id}/promote")
async def promote_actor(
    actor_id: str,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> JSONResponse:
    """Promote a provisional actor to the agent registry. Superadmin only.

    Promotion is the Weave's highest-stakes decision: it turns a provisional
    correlation into an actor the product acts on. So the gate is
    ``require_superadmin`` over the verified principal, and the request is
    audited *before* it is forwarded, so an attempted promotion cannot happen
    unrecorded even if signal-ingest then refuses it. The event names a
    request; the outcome (``actor_promoted``) is signal-ingest's own record.

    ``write=True``: a write acts for the caller's own tenant, never ``*``, so a
    superadmin promotes actors in the tenant it is bound to and signal-ingest
    answers another tenant's actor like an absent one (404), passed through.
    """
    quoted = urllib.parse.quote(actor_id, safe="")
    # The literal sits at the call site so test_audit_event_types can resolve
    # it; EVENT_ACTOR_PROMOTE names the same string for callers and tests.
    await _audit_outbound_request(
        principal, "actor.promote_requested", {"actor_id": actor_id}, "actor promote",
    )
    return await _proxy("POST", f"/api/v1/actors/{quoted}/promote", principal, write=True)


@router.get("/coverage")
async def get_coverage(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Get signal coverage across observation layers."""
    return await _proxy("GET", "/api/v1/coverage", principal)


@router.post("/correlate")
async def run_correlation(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Trigger a correlation engine run."""
    return await _proxy("POST", "/api/v1/correlate", principal)


@router.get("/store/stats")
async def get_store_stats(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Get store diagnostics — observation counts, actor stats, store type."""
    return await _proxy("GET", "/api/v1/store/stats", principal)


@router.post("/collectors/seed")
async def seed_collectors(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> JSONResponse:
    """Seed the signal collectors with initial data."""
    return await _proxy("POST", "/api/v1/collectors/seed", principal, write=True)


def install_signal_fusion_api(app: Any) -> None:
    """Mount the signal fusion router on the FastAPI app."""
    app.include_router(router)
