"""AuthZ-CTX across the Olly -> Orbit A2A hop.

Olly carries the COIN-minted token as the ``X-AuthZ-CTX`` header on the A2A
``message/send`` to Orbit. Orbit re-validates it (HS256 with the shared secret),
intersects the inbound ``permitted_actions`` with its own local grant, and can
only narrow (drop an action or lower a limit), never widen. The same
``authz_ctx_id`` flows across the hop, so 'who authorized this restart?' is a
single-key audit lookup. This is the receiving-agent half of the chain the
in-cluster olly-authz service issues.
"""

import base64
import hashlib
import hmac
import json
import logging
import time

from . import config

log = logging.getLogger("olly-sentinel")


def _unb64(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def decode(token: str) -> dict:
    """Verify the HS256 signature + exp/nbf against the shared secret and return
    the claims. Matches olly-authz's stdlib jwtutil. Raises ValueError on any
    failure so a caller turns a bad token into a clean DENY."""
    parts = (token or "").split(".")
    if len(parts) != 3:
        raise ValueError("malformed token")
    signing_input = parts[0] + "." + parts[1]
    expected = base64.urlsafe_b64encode(
        hmac.new(config.AUTHZ_JWT_SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    ).rstrip(b"=").decode()
    if not hmac.compare_digest(expected, parts[2]):
        raise ValueError("bad signature")
    claims = json.loads(_unb64(parts[1]))
    now = int(time.time())
    if claims.get("exp", 0) < now:
        raise ValueError("token expired")
    if claims.get("nbf", 0) > now + 5:
        raise ValueError("token not yet valid")
    return claims


def to_map(permitted_actions: list) -> dict:
    return {p["action"]: int(p.get("limit", 0)) for p in permitted_actions if p.get("action")}


def to_list(mapping: dict) -> list:
    return [{"action": a, "limit": mapping[a]} for a in sorted(mapping)]


def intersect(inbound: list, local_grants: dict) -> list:
    """Narrow-only intersection: keep actions in both, take the lower limit."""
    ctx = to_map(inbound)
    out = {}
    for action, limit in ctx.items():
        if action in local_grants:
            out[action] = min(limit, int(local_grants[action]))
    return to_list(out)


def allows(permitted_actions: list, action: str) -> bool:
    mapping = to_map(permitted_actions)
    return action in mapping and mapping[action] > 0


async def orbit_ctx_dispatch(request, call_next):
    """Starlette middleware for Orbit's A2A endpoint. Gates the ``message/send``
    (POST /) on a valid AuthZ-CTX that still permits at least one action after
    narrowing by Orbit's local grant. The agent card (GET) is never gated."""
    from starlette.responses import JSONResponse

    path = (request.url.path or "/").rstrip("/") or "/"
    if not config.AUTHZ_ENABLED or request.method != "POST" or path != "/":
        return await call_next(request)

    ctx = request.headers.get("x-authz-ctx", "")
    if not ctx:
        log.warning("Orbit A2A: inbound message carried no AuthZ-CTX; denying")
        return JSONResponse({"error": "missing AuthZ-CTX"}, status_code=401)
    try:
        claims = decode(ctx)
    except Exception as exc:  # noqa: BLE001 - a bad token is a clean deny
        log.warning("Orbit A2A: AuthZ-CTX invalid (%s); denying", exc)
        return JSONResponse({"error": f"AuthZ-CTX invalid: {exc}"}, status_code=401)

    narrowed = intersect(claims.get("permitted_actions", []), config.ORBIT_LOCAL_GRANT)
    requested = request.headers.get("x-authz-action", "")
    if requested:
        # The delegated action must survive narrowing by Orbit's local grant.
        if not allows(narrowed, requested):
            log.warning("Orbit A2A: AuthZ-CTX does not permit %r after narrowing (ctx=%s); denying",
                        requested, claims.get("authz_ctx_id"))
            return JSONResponse(
                {"error": f"AuthZ-CTX does not permit '{requested}' after narrowing by Orbit's grant"},
                status_code=403)
    elif not narrowed:
        log.warning("Orbit A2A: AuthZ-CTX permits nothing after narrowing (ctx=%s); denying",
                    claims.get("authz_ctx_id"))
        return JSONResponse({"error": "AuthZ-CTX permits no action for Orbit after narrowing"},
                            status_code=403)

    log.info(
        'AUDIT {"path":"orbit","event":"authz_ctx_validated","authz_ctx_id":"%s",'
        '"username":"%s","narrowed_actions":%d}',
        claims.get("authz_ctx_id", ""), claims.get("username", ""), len(narrowed),
    )
    resp = await call_next(request)
    resp.headers["X-AuthZ-CTX-Id"] = str(claims.get("authz_ctx_id", ""))
    resp.headers["X-AuthZ-Narrowed"] = str(len(narrowed))
    return resp
