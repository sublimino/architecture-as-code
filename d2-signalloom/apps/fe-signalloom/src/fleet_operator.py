"""Superadmin-gated proxy for the two fleet routes only the operator key may call.

The decision this file records, because it is not obvious from either side:

``fleet-manager``'s caller-key table (``apps/fleet-manager/base/deployment.yaml``,
semantics in ``callerauth.go``) grants the ``dashboard`` key ``stun``, ``deploy``,
``scan`` and ``reset``. ``recover`` and ``resume`` belong to the ``operator``
break-glass key alone, deliberately: ``/recover`` thaws every stunned agent at
once and never consulted the resume-token governance that guards ``/resume``.

So the Fleet page's **Recover** button answered 403 for everybody, superadmin
included: the dashboard's nginx verifies a superadmin through
``/api/v1/auth/check`` and then swaps in the ``dashboard`` key, which has no
``recover`` scope. Giving the ``dashboard`` key that scope would be the wrong
fix twice over -- it would put break-glass in the browser's reach, and the key
is presented by nginx for every ``/fleet-api/`` call, so the grant could not be
narrowed to the one button.

Instead the capability is proxied here. The operator key is read from this
pod's environment and never leaves it; the browser presents only its Dex token,
and ``require_superadmin`` decides from the verified principal, never from a
header, query parameter or body field the client can author. Each call is
audited before it is forwarded, so an attempted thaw cannot happen unrecorded
even if fleet-manager then refuses it.

``resume`` is included alongside ``recover`` because it is the same key and the
same gate, and because it is the single-agent form the remote contract's resume
path needs (``docs/EAP/remote-contract.md``, "Stun state and resume"): with no
caller able to present the operator key, a frozen pod on a remote cluster had
no product path back, which ``docs/EAP/faq-and-limits.md`` carried as a limit.

Not proxied: ``stun``, ``deploy``, ``scan``, ``reset``. The ``dashboard`` key
already carries those, so routing them through here would add a second path to
the same capability for no gain.
"""
from __future__ import annotations

import logging
import os
from typing import Annotated, Any
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Body, Depends
from fastapi.responses import JSONResponse

from api_compat import (
    ERROR_RESPONSES,
    FLEET_MANAGER_URL,
    APIError,
    Principal,
    _audit_outbound_request,
)
from superadmin import require_superadmin

logger = logging.getLogger(__name__)

#: fleet-manager's ``operator`` break-glass key, from Secret
#: ``fleet-manager-caller-keys`` key ``operator``. Unset means this deployment
#: has no break-glass path, which is reported as such rather than forwarded and
#: refused: a 401 from fleet-manager would read to the operator as "the fleet
#: refused me", not "this portal was never given the key".
FLEET_MANAGER_OPERATOR_KEY_ENV = "FLEET_MANAGER_OPERATOR_KEY"

#: Recovering the fleet touches every stunned agent, so it is given more room
#: than the 10 s a single stun gets.
_TIMEOUT_SECONDS = 30.0

#: Event types admitted by migration 052.
EVENT_FLEET_RECOVER = "fleet.recover_requested"
EVENT_FLEET_RESUME = "fleet.resume_requested"

router = APIRouter(tags=["fleet"])


def _operator_key() -> str:
    return os.environ.get(FLEET_MANAGER_OPERATOR_KEY_ENV, "").strip()


def _require_operator_key() -> str:
    key = _operator_key()
    if not key:
        raise APIError(
            503,
            "fleet_operator_key_unavailable",
            "This portal holds no fleet-manager operator key, so it cannot recover or resume",
        )
    return key


async def _forward(
    principal: Principal,
    *,
    path: str,
    body: dict[str, Any] | None,
) -> JSONResponse:
    """Send one already-audited, already-authorised request to fleet-manager.

    Deliberately does *not* audit: ``test_audit_event_types`` resolves an event
    type one hop from the ``_audit_outbound_request`` call site, so auditing
    here would put the literal two hops away and the guard would refuse the
    call site as unresolvable -- correctly, since an unresolvable event type
    reaches the CHECK constraint unvalidated. Each route therefore audits with
    its own literal before calling this.
    """
    if not FLEET_MANAGER_URL:
        raise APIError(
            503, "fleet_manager_unavailable", "This deployment has no fleet-manager",
        )

    # Re-read rather than taking it as an argument, so the key never sits in a
    # frame the caller can see or log; the route has already proved it exists.
    key = _require_operator_key()
    url = f"{FLEET_MANAGER_URL.rstrip('/')}{path}"
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_TIMEOUT_SECONDS)) as client:
            response = await client.post(
                url, json=body, headers={"Authorization": f"Bearer {key}"},
            )
    except httpx.HTTPError as exc:
        logger.warning("fleet operator proxy: fleet-manager unreachable", exc_info=True)
        raise APIError(
            502, "fleet_manager_unreachable", f"fleet-manager unreachable: {type(exc).__name__}",
        ) from None

    try:
        payload: Any = response.json()
    except ValueError:
        payload = {"detail": response.text[:512]}

    # fleet-manager's status is passed through rather than flattened: the
    # operator needs to see its refusal as its refusal.
    return JSONResponse(status_code=response.status_code, content=payload)


@router.post("/api/v1/fleet/recover", responses=ERROR_RESPONSES)
async def recover_fleet(
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> JSONResponse:
    """Thaw every stunned agent. Superadmin only, operator key presented server-side."""
    _require_operator_key()
    # Audited before the call, not after: if the write fails the request fails
    # and fleet-manager is never asked, so no thaw can happen unrecorded.
    # The event type is a literal at the call site, not the module constant:
    # test_audit_event_types resolves literals and one-hop parameters, and an
    # event type it cannot resolve reaches the CHECK constraint unvalidated.
    # EVENT_FLEET_RECOVER below names the same string for callers and tests.
    await _audit_outbound_request(
        principal, "fleet.recover_requested", {"scope": "fleet"}, "fleet recover",
    )
    return await _forward(principal, path="/api/v1/fleet/recover", body=None)


@router.post("/api/v1/fleet/resume/{agent_id}", responses=ERROR_RESPONSES)
async def resume_agent(
    agent_id: str,
    principal: Annotated[Principal, Depends(require_superadmin)],
    payload: dict[str, Any] | None = Body(default=None),
) -> JSONResponse:
    """Resume one agent, local or remote. Superadmin only, operator key server-side."""
    reason = None
    if isinstance(payload, dict):
        candidate = payload.get("reason")
        if isinstance(candidate, str) and candidate.strip():
            reason = candidate.strip()

    _require_operator_key()
    await _audit_outbound_request(
        principal, "fleet.resume_requested", {"agent_id": agent_id, "reason": reason}, "fleet resume",
    )
    return await _forward(
        principal,
        path=f"/api/v1/fleet/resume/{quote(agent_id, safe='')}",
        body={"agent_id": agent_id, "reason": reason} if reason else {"agent_id": agent_id},
    )


def install_fleet_operator_api(app: Any) -> None:
    """Mount the operator proxy once."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is recover_fleet:
            return
    app.include_router(router)
