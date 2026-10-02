"""GET /api/v1/auth/check: the dashboard's gate in front of fleet-manager.

The dashboard's nginx sends every ``/fleet-api/`` request here first
(``auth_request``) with the browser's own ``Authorization`` header. Only a
204 lets nginx forward the request, and only then does nginx swap the
browser's token for the dashboard's fleet-manager caller key. So this decides
who may stun, deploy, scan or reset through the dashboard: a validated Dex
token whose principal is a superadmin. A missing or invalid token is 401 and a
valid non-superadmin is 403, both from the existing dependencies.

It returns no body and changes nothing, so nginx can call it on every request.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, Response

from api_compat import Principal
from superadmin import require_superadmin

router = APIRouter()


@router.get("/api/v1/auth/check", status_code=204, response_class=Response)
async def auth_check(_principal: Annotated[Principal, Depends(require_superadmin)]) -> Response:
    return Response(status_code=204)


def install_auth_check_api(app: Any) -> None:
    """Mount the auth-check router once."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is auth_check:
            return
    app.include_router(router)
