"""Superadmin-gated proxy for signal-ingest's actor promotion.

The Weave page rendered a **Promote** button for every actionable actor and
wired it to nothing (``docs/EAP/faq-and-limits.md`` carried it as a limit).
The route it needed, ``POST /api/v1/actors/{id}/promote``, lives in
signal-ingest behind the gateway key, which the browser must never hold. So
the capability is proxied here on the ``fleet_operator`` pattern:

* the gate is ``require_superadmin`` over the verified principal, never a
  header, query parameter or body field the client can author;
* the request is audited *before* it is forwarded, so an attempted promotion
  cannot happen unrecorded even if signal-ingest then refuses it;
* the gateway key and the acting-tenant headers come from
  ``ingest_client.ingest_headers(principal, write=True)``: a write always acts
  for the caller's own tenant, so a superadmin promotes actors in the tenant
  it is bound to. signal-ingest answers another tenant's actor exactly like an
  absent one (404), which is passed through rather than flattened.

Promotion is the Weave's highest-stakes decision -- it turns a provisional
correlation into an actor the product will act on -- which is why it is
superadmin-only here even though signal-ingest itself would accept any
``tenant:act-for`` write.
"""
from __future__ import annotations

import logging
import os
from typing import Annotated, Any
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from api_compat import ERROR_RESPONSES, APIError, Principal, _audit_outbound_request
from ingest_client import ingest_headers
from superadmin import require_superadmin

logger = logging.getLogger(__name__)

SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT_SECONDS = 10.0

#: Event type admitted by migration 055.
EVENT_ACTOR_PROMOTE = "actor.promote_requested"

router = APIRouter(tags=["weave"])


@router.post("/api/v1/actors/{actor_id}/promote", responses=ERROR_RESPONSES)
async def promote_actor(
    actor_id: str,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> JSONResponse:
    """Promote one provisional actor. Superadmin only, gateway key server-side."""
    if not actor_id.strip():
        raise APIError(400, "actor_id_required", "actor id is required")
    if not SIGNAL_INGEST_URL:
        raise APIError(503, "signal_ingest_unavailable", "This deployment has no signal-ingest")

    # Headers first: a missing gateway key is this portal's fault and is
    # reported as such (503) before anything is recorded or sent.
    headers = ingest_headers(principal, write=True)

    # Audited before the call, with the literal at the call site so
    # test_audit_event_types can resolve it. EVENT_ACTOR_PROMOTE names the same
    # string for callers and tests.
    await _audit_outbound_request(
        principal, "actor.promote_requested", {"actor_id": actor_id}, "actor promote",
    )

    url = f"{SIGNAL_INGEST_URL.rstrip('/')}/api/v1/actors/{quote(actor_id, safe='')}/promote"
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_TIMEOUT_SECONDS)) as client:
            response = await client.post(url, headers=headers)
    except httpx.HTTPError as exc:
        logger.warning("actor promote proxy: signal-ingest unreachable", exc_info=True)
        raise APIError(
            502, "signal_ingest_unreachable", f"signal-ingest unreachable: {type(exc).__name__}",
        ) from None

    try:
        payload: Any = response.json()
    except ValueError:
        payload = {"detail": response.text[:512]}
    # signal-ingest's status is passed through: 404 for an actor the caller's
    # tenant cannot see, 409 for one already promoted.
    return JSONResponse(status_code=response.status_code, content=payload)


def install_actor_promote_api(app: Any) -> None:
    """Mount the promote proxy once."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is promote_actor:
            return
    app.include_router(router)
