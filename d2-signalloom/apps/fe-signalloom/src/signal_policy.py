"""Policy review API routes: the dashboard's door onto what the policy concluded.

Proxies ``/api/signals/policy/*`` to signal-ingest ``/api/v1/policy/*`` with exactly the tenant
scoping the existing ``/api/signals/observations`` proxy applies — the same gateway static key, the
same ``ingest_headers`` helper, so the verified dashboard user's tenant comes from the validated
``Principal`` and never from anything the browser writes.

Three reads and one write:

  GET  /api/signals/policy/findings   -> GET  /api/v1/policy/findings
  GET  /api/signals/policy/decisions  -> GET  /api/v1/policy/decisions
  GET  /api/signals/policy/rates      -> GET  /api/v1/policy/rates
  POST /api/signals/policy/decisions/{decision_id}/review
                                      -> POST /api/v1/policy/decisions/{id}/review

# Why the write has its own gate

Recording a verdict is not a read with a side effect. It puts a named person's judgement into the
evidence, and that record is the thing a regulator, an incident review or a tuning argument later
leans on. So it is gated server-side, from the validated token only, by ``require_policy_reviewer``
below — never by frontend state, a header, or a body field.

The gate is ``superadmin.is_superadmin``, which is the platform's existing server-side identity
check (the same one ``auth_check`` puts in front of every mutating fleet control). That makes every
other authenticated dashboard user read-only with respect to review: they see the findings, the
decisions and the rates, and a POST is 403.

That choice is deliberately conservative and deliberately swappable. The honest alternative is
``platform_users.role`` (admin / editor / viewer), which is the right long-term answer and is not
used here because it needs a database round trip inside a proxy that has none today, and a review
gate that fails open when the pool is down is worse than one that is narrow. When the role lookup
is available, ``require_policy_reviewer`` is the single function to change — nothing else in this
module knows how the decision was reached.

# Reviewer identity

``ingest_headers`` already sends ``X-SignalLoom-Acting-Subject: principal.subject``, and
signal-ingest reads it as the reviewer precisely because the gateway holds ``tenant:act-for``: the
gateway's own key subject is shared by every user behind it, so a verdict attributed to the key
would say "the dashboard" rather than name a person. Nothing in this module needs to send the
reviewer separately, and nothing in it may accept one from the caller.
"""
from __future__ import annotations

import json
import logging
import urllib.parse
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any

import httpx
from fastapi import APIRouter, Body, Depends, Query
from fastapi.responses import JSONResponse

from api_compat import APIError, Principal, authenticated_principal
from ingest_client import ingest_headers, ingest_headers_for_tenant
from superadmin import is_superadmin

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/signals/policy", tags=["signal-policy"])

# The closed vocabularies, mirrored from signal-ingest so a typo is a 400 here rather than a
# round trip. Kept as literals rather than imported because the two services are separate
# deployables; api/policy_routes_test.go and tests/test_signal_policy.py both pin them.
WINDOWS: frozenset[str] = frozenset({"5m", "10m", "30m", "90m"})
BUCKETS: frozenset[str] = frozenset({"1m", "5m"})
VERDICTS: frozenset[str] = frozenset({"true_positive", "false_positive", "needs_info"})
MAX_NOTE_CHARS = 500

# signal-ingest's own ceiling (api.MaxPolicyLimit). The EFFECTIVE ceiling upstream is lower --
# ProtectedRouter's enumeration budget refuses a limit above RouterOptions.MaxPageSize, 100 in
# production -- so this bound admits requests upstream will refuse. It is left at the contract
# value rather than hardcoded to 100 so that raising MaxPageSize does not need a gateway change;
# an over-large limit comes back as signal-ingest's own 400, which is the correct authority.
MAX_LIMIT = 500

_TIMEOUT = 10.0


def require_policy_reviewer(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Principal:
    """The server-side gate on recording a verdict. Identity from the validated token only."""
    if not is_superadmin(principal):
        raise APIError(
            403,
            "policy_review_forbidden",
            "Recording a policy review requires reviewer access",
        )
    return principal


def _signal_ingest_url() -> str:
    """Read the upstream base URL at call time.

    Deliberately not a module-level constant, unlike ``signal_fusion._SIGNAL_INGEST_URL``: a
    constant captured at import time cannot be overridden by a test or by a config change without
    reloading the module, and the review routes are the ones a test most needs to point at a stub.
    """
    import os

    return os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")


async def _proxy(
    method: str,
    path: str,
    principal: Principal,
    *,
    write: bool = False,
    headers: dict[str, str] | None = None,
    **kwargs: Any,
) -> JSONResponse:
    """Forward one request to signal-ingest as the gateway, acting for ``principal``'s tenant.

    The headers are built before the request so a missing gateway key is its own 503 rather than
    being folded into the 502 below, and so a request is never sent anonymously. Mirrors
    ``signal_fusion._proxy``; kept as its own function rather than imported so the policy routes
    do not inherit a future change to the observations proxy by accident.
    """
    if headers is None:
        headers = ingest_headers(principal, write=write)
    try:
        async with httpx.AsyncClient(base_url=_signal_ingest_url(), timeout=_TIMEOUT) as client:
            resp = await client.request(method, path, headers=headers, **kwargs)
            try:
                content = resp.json()
            except ValueError:
                # An upstream status with a non-JSON body (a proxy error page, an empty 204) must
                # not become a 502: the status is the answer, and inventing a JSON body for it
                # would hide which hop refused.
                content = {"error": "upstream_non_json", "status": resp.status_code}
            return JSONResponse(status_code=resp.status_code, content=content)
    except httpx.ConnectError as exc:
        logger.warning("signal-ingest service unreachable at %s", _signal_ingest_url())
        raise APIError(502, "upstream_unavailable", "signal-ingest service unreachable") from exc
    except httpx.TimeoutException as exc:
        logger.warning("signal-ingest request timed out: %s %s", method, path)
        raise APIError(504, "upstream_timeout", "signal-ingest request timed out") from exc
    except APIError:
        raise
    except Exception as exc:
        logger.exception("signal-ingest policy proxy error: %s %s", method, path)
        raise APIError(502, "upstream_unavailable", "signal-ingest proxy error") from exc


def _read_params(
    window: str | None,
    since: str | None,
    tenant: str | None,
    limit: int | None,
) -> dict[str, Any]:
    """Validate and assemble the query for a policy read.

    ``window`` and ``since`` are mutually exclusive, matching upstream: picking one silently would
    make the other a no-op that the caller reasonably believes is in force.

    ``tenant`` is passed through unvalidated as a VALUE but is not a privilege: signal-ingest
    resolves it against the acting tenant this gateway sends and answers 403 for a scoped user
    naming anyone else. The gateway must not pre-approve it, because the gateway does not know
    whether the user is a superadmin reading as ``*``.
    """
    if window is not None and since is not None:
        raise APIError(400, "invalid_window", "window and since are mutually exclusive")
    if window is not None and window not in WINDOWS:
        raise APIError(400, "invalid_window", f"window must be one of {sorted(WINDOWS)}")
    if limit is not None and not 1 <= limit <= MAX_LIMIT:
        raise APIError(400, "invalid_limit", f"limit must be between 1 and {MAX_LIMIT}")

    params: dict[str, Any] = {}
    if window is not None:
        params["window"] = window
    if since is not None:
        params["since"] = since
    if tenant is not None:
        params["tenant"] = tenant
    if limit is not None:
        params["limit"] = limit
    return params


@router.get("/findings")
async def get_policy_findings(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    window: str | None = None,
    since: str | None = None,
    tenant: str | None = None,
    limit: int | None = Query(default=None),
) -> JSONResponse:
    """Stage-1 policy findings, newest first, scoped to the user's tenant."""
    params = _read_params(window, since, tenant, limit)
    return await _proxy("GET", "/api/v1/policy/findings", principal, params=params)


@router.get("/decisions")
async def get_policy_decisions(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    window: str | None = None,
    since: str | None = None,
    tenant: str | None = None,
    limit: int | None = Query(default=None),
) -> JSONResponse:
    """Stage-2 policy decisions, each carrying its latest review or ``null``."""
    params = _read_params(window, since, tenant, limit)
    return await _proxy("GET", "/api/v1/policy/decisions", principal, params=params)


@router.get("/rates")
async def get_policy_rates(
    principal: Annotated[Principal, Depends(authenticated_principal)],
    window: str | None = None,
    since: str | None = None,
    tenant: str | None = None,
    bucket: str | None = None,
) -> JSONResponse:
    """Bucketed observation counts per layer per source, for the live chart."""
    if bucket is not None and bucket not in BUCKETS:
        raise APIError(400, "invalid_bucket", f"bucket must be one of {sorted(BUCKETS)}")
    params = _read_params(window, since, tenant, None)
    if bucket is not None:
        params["bucket"] = bucket
    return await _proxy("GET", "/api/v1/policy/rates", principal, params=params)


@router.post("/decisions/{decision_id}/review", status_code=201)
async def review_policy_decision(
    decision_id: str,
    principal: Annotated[Principal, Depends(require_policy_reviewer)],
    body: Annotated[dict[str, Any], Body()],
) -> JSONResponse:
    """Record an objective value judgement against one policy decision.

    The body is reassembled from the two fields the contract names rather than forwarded as
    received. Upstream decodes closed-world and would refuse an extra field anyway, but a proxy
    that forwards whatever arrived is how a ``reviewer`` or ``reviewed_at`` field eventually
    reaches a handler that trusts it. Only the verdict and the note are the caller's to set; the
    reviewer and the timestamp are the servers'.
    """
    if not isinstance(body, dict):
        raise APIError(400, "invalid_review", "review body must be an object")
    verdict = body.get("verdict")
    if verdict not in VERDICTS:
        raise APIError(400, "invalid_verdict", f"verdict must be one of {sorted(VERDICTS)}")
    note = body.get("note", "")
    if note is None:
        note = ""
    if not isinstance(note, str):
        raise APIError(400, "invalid_note", "note must be a string")
    if len(note) > MAX_NOTE_CHARS:
        raise APIError(400, "invalid_note", f"note must be at most {MAX_NOTE_CHARS} characters")
    if not decision_id or "/" in decision_id:
        raise APIError(400, "invalid_decision_id", "decision id is required")

    quoted = urllib.parse.quote(decision_id, safe="")
    path = f"/api/v1/policy/decisions/{quoted}/review"
    payload = {"verdict": verdict, "note": note}
    resp = await _proxy("POST", path, principal, write=True, json=payload)
    if resp.status_code != 404 or not is_superadmin(principal):
        return resp
    # A write acts for one real tenant, the reviewer's own, and signal-ingest answers 404 for a
    # decision that tenant cannot see. A superadmin reads every tenant, so the decision they are
    # looking at on /signals may belong to another one (the Kusari pilot: demo-user is
    # tenant-demo, the decisions are kusari's). Resolve the owner through the same read scope
    # the page used and act for that tenant, once. Found 2026-10-06 on the first live review.
    tenant = await _decision_tenant(decision_id, principal)
    if tenant is None or tenant == principal.tenant:
        return resp
    headers = ingest_headers_for_tenant(tenant, principal.subject)
    return await _proxy("POST", path, principal, write=True, headers=headers, json=payload)


# How far back a superadmin's review may reach when the decision is another tenant's. The page
# offers 90 minutes; a `since` view can go further, and 30 days is the longest a decision is
# meant to wait for a verdict.
_DECISION_LOOKUP_SPAN = timedelta(days=30)
# signal-ingest's ProtectedRouter applies its enumeration budget (MaxPageSize, 100) to every
# enumerating route before the policy handler's own MaxPolicyLimit (500) is consulted, so 100
# is the largest page a lookup can ask for. The listing is newest first, so this reaches the
# 100 most recent decisions in the span.
_DECISION_LOOKUP_LIMIT = 100


async def _decision_tenant(decision_id: str, principal: Principal) -> str | None:
    """Which tenant owns ``decision_id``, as seen through ``principal``'s read scope."""
    since = (datetime.now(timezone.utc) - _DECISION_LOOKUP_SPAN).strftime("%Y-%m-%dT%H:%M:%SZ")
    listing = await _proxy(
        "GET",
        "/api/v1/policy/decisions",
        principal,
        params={"since": since, "limit": _DECISION_LOOKUP_LIMIT},
    )
    if listing.status_code != 200:
        return None
    try:
        rows = json.loads(listing.body)
    except ValueError:
        return None
    if not isinstance(rows, list):
        return None
    for row in rows:
        if isinstance(row, dict) and row.get("id") == decision_id:
            tenant = row.get("tenant_id")
            return tenant if isinstance(tenant, str) and tenant else None
    return None


def install_signal_policy_api(app: Any) -> None:
    """Mount the policy review router once."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is review_policy_decision:
            return
    app.include_router(router)
