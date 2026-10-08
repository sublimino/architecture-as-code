"""``GET /api/v1/me``: the server's answer to "who am I and what am I".

Why this exists even though ``GET /api/capabilities`` already reports
``tenant``/``is_superadmin``: capabilities is a large, workload-parameterised
response (it takes ``workload_id`` and builds a per-action capability matrix),
so the dashboard cannot call it as a cheap identity probe on mount, and its
shape is pinned by contract tests that make it awkward to depend on for a
boot-time decision. ``/api/v1/me`` is the minimal, stable triple the dashboard
needs to stop deciding superadmin client-side:

* ``subject`` — the verified JWT ``sub``, never a header or query parameter
* ``tenant`` — the authorisation decision, from the server-side subject map
* ``superadmin`` — ``superadmin.is_superadmin`` over the same principal the
  server itself uses for ``require_superadmin``

Before this route the dashboard matched ``demo-user@signalloom.local`` in the
browser (``auth/superadmin.ts``), so the client's idea of superadmin and the
server's could disagree the moment ``API_SUPERADMIN_EMAILS`` was configured to
anything other than its default. The dashboard now follows this route and the
name match is a fallback only for the pre-flight window before it answers.

It reads no table: identity is entirely a property of the validated token plus
process configuration, so there is nothing here to scope by tenant.
"""
from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict

from api_compat import ERROR_RESPONSES, Principal, authenticated_principal
from superadmin import is_superadmin

router = APIRouter(tags=["identity"])


class MeResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject: str
    tenant: str
    email: str | None = None
    superadmin: bool


@router.get("/api/v1/me", response_model=MeResponse, responses=ERROR_RESPONSES)
@router.get("/v1/me", response_model=MeResponse, responses=ERROR_RESPONSES)
@router.get("/api/me", response_model=MeResponse, responses=ERROR_RESPONSES)
async def me(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> MeResponse:
    return MeResponse(
        subject=principal.subject,
        tenant=principal.tenant,
        email=principal.email,
        superadmin=is_superadmin(principal),
    )


def install_me_api(app: Any) -> None:
    """Mount the identity router once."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is me:
            return
    app.include_router(router)
