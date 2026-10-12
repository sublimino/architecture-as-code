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
    TRUST_TOPOLOGY_URL,
    APIError,
    Principal,
    _error_response,
    _now_iso,
    agents,
    authenticated_principal,
    authenticated_tenant,
)
from federation_state import (
    LOCAL_READ_SUBPATHS,
    build_federation_state,
    project_subpath,
)
from ingest_client import ACTING_TENANT_HEADER, ALL_TENANTS, ingest_headers

logger = logging.getLogger(__name__)

router = APIRouter(tags=["federation"])

SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
_TIMEOUT = float(os.getenv("FEDERATION_PROXY_TIMEOUT", "10.0"))

SERVER_SPIFFE_ID = os.getenv(
    "SERVER_SPIFFE_ID",
    "spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom",
)


def _is_unregistered_route(resp: httpx.Response) -> bool:
    """True only for signal-ingest's registry denial of a path it does not serve."""
    if resp.status_code != 403:
        return False
    try:
        return resp.json() == {"error": "unregistered_route"}
    except ValueError:
        return False


async def proxy_federation_request(
    request: Request,
    subpath: str = "",
    tenant_id: str | None = None,
    *,
    principal: Principal,
) -> Response:
    """Forward a request to the signal-ingest federation endpoints with tenant isolation.

    The upstream call presents fe-signalloom's own signal-ingest gateway key with the acting
    tenant and subject (``ingest_client.ingest_headers``), exactly like every other signal-ingest
    proxy; the caller's own credential is never forwarded. signal-ingest authenticates with named
    static keys (SLTM), so forwarding the browser's Dex token - the pre-SLTM shape - was answered
    with 401 ``authentication_failed`` and the dashboard's Federated Services page errored. Seen
    on the 2026-10-03 cold rebuild, where this was the one proxy still forwarding the credential.
    """
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

    # Cross-tenant isolation (IDOR protection)
    if tenant_id:
        # Check query parameters
        req_tenant = request.query_params.get("tenant") or request.query_params.get("tenant_id")
        if req_tenant and req_tenant != tenant_id:
            logger.warning(
                "federation IDOR rejected: query tenant %r does not match authenticated tenant %r",
                req_tenant,
                tenant_id,
            )
            return _error_response(
                403,
                "tenant_mismatch",
                f"Token tenant '{tenant_id}' does not match query tenant '{req_tenant}'",
            )

        # Check path parameters
        path_parts = clean_subpath.split("/")
        for idx, part in enumerate(path_parts):
            if part in ("tenants", "configurations", "configs") and idx + 1 < len(path_parts):
                target_tenant = path_parts[idx + 1]
                if target_tenant and target_tenant != tenant_id:
                    logger.warning(
                        "federation IDOR rejected: path tenant %r does not match authenticated tenant %r",
                        target_tenant,
                        tenant_id,
                    )
                    return _error_response(
                        403,
                        "tenant_mismatch",
                        f"Token tenant '{tenant_id}' does not match path tenant '{target_tenant}'",
                    )

        # Check body payload for mutating operations
        if body_bytes:
            try:
                body_json = json.loads(body_bytes)
                if isinstance(body_json, dict):
                    payload_tenant = body_json.get("tenant_id") or body_json.get("tenant")
                    if payload_tenant and payload_tenant != tenant_id:
                        logger.warning(
                            "federation IDOR rejected: body tenant %r does not match authenticated tenant %r",
                            payload_tenant,
                            tenant_id,
                        )
                        return _error_response(
                            403,
                            "tenant_mismatch",
                            f"Token tenant '{tenant_id}' does not match payload tenant '{payload_tenant}'",
                        )
            except Exception:
                pass

    headers: dict[str, str] = {
        "Accept": "application/json",
    }
    if body_bytes is not None:
        headers["Content-Type"] = "application/json"
    if tenant_id:
        headers["X-Tenant-ID"] = tenant_id
        try:
            from tenant_isolation import get_tenant_spiffe_id
            headers["X-SPIFFE-ID"] = get_tenant_spiffe_id(tenant_id)
        except Exception:
            headers["X-SPIFFE-ID"] = f"spiffe://signalloom.demo/ns/fe-signalloom/sa/{tenant_id}"
    else:
        headers["X-SPIFFE-ID"] = SERVER_SPIFFE_ID

    # Preserve allowed client headers, strictly stripping client-supplied identity/SPIFFE headers
    for k, v in request.headers.items():
        k_lower = k.lower()
        if k_lower.startswith("x-") and k_lower not in (
            "x-tenant-id",
            "host",
            "x-spiffe-id",
            "x-spiffe-svid",
            # signal-ingest scopes a gateway request to this tenant. A client must never be able
            # to name it, whatever credential a later change sends alongside.
            "x-signalloom-acting-tenant",
            "x-signalloom-acting-subject",
        ):
            headers[k] = v

    # Last, so nothing copied above can shadow the gateway identity.
    upstream_identity = ingest_headers(principal, write=request.method not in ("GET", "HEAD", "OPTIONS"))
    headers.update(upstream_identity)

    params = dict(request.query_params)
    # A superadmin read acts for every tenant ("*"); naming one tenant in the query would
    # contradict the acting header, so it is only added when the request acts for one tenant.
    if tenant_id and "tenant" not in params and upstream_identity[ACTING_TENANT_HEADER] != ALL_TENANTS:
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
            "upstream_unavailable",
            f"signal-ingest federation proxy error: {exc}",
        )

    # If upstream signal-ingest does not implement the requested federation route, say so.
    #
    # This branch used to substitute a hardcoded dataset - zones, federations, services,
    # policies, SPIFFE identities with fixed expiry timestamps, a fixed event log, and a
    # summary carrying attestation_success_rate=99.8 and active_alerts=0. None of it was a
    # function of any request input or of any observed system state: W9 perturbation
    # (test_w9_federation_unserved_route_does_not_fabricate) showed all seven read subpaths
    # returning a byte-identical 200 body across two different authenticated tenants. And it
    # was not a degraded-mode fallback - signal-ingest registers no /api/v1/federation handler
    # outside its own tests, so default-deny (api/auth.go) answers every such request with
    # 403 {"error":"unregistered_route"} and the invented dataset was what the dashboard got
    # 100% of the time in live mode.
    #
    # The honest answer is the one this proxy already gives for every other upstream failure:
    # a structured error naming the cause. ``upstream_route_not_served`` is distinct from
    # ``upstream_unavailable`` (reachable but failing) and from a real 403 denial, so a caller
    # can tell "this capability is not deployed" from "this capability is broken" from
    # "you are not allowed". A federation figure that cannot be derived is not emitted.
    if request.method == "GET" and (resp.status_code == 404 or _is_unregistered_route(resp)):
        logger.info(
            "signal-ingest %d on federation subpath %r: route not served upstream",
            resp.status_code,
            clean_subpath,
        )
        return _error_response(
            502,
            "upstream_route_not_served",
            "signal-ingest does not serve federation route "
            f"{target_path!r}; no federation state is available to report",
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

    # If upstream returned non-JSON content-type
    if not ("application/json" in resp_content_type.lower() or "+json" in resp_content_type.lower()):
        logger.warning(
            "signal-ingest returned non-JSON content type: status=%d content_type=%r",
            resp.status_code,
            resp_content_type,
        )
        return _error_response(
            502,
            "invalid_upstream_response",
            f"signal-ingest returned non-JSON content type {resp_content_type!r} (status {resp.status_code})",
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


_TOPOLOGY_TIMEOUT = float(os.getenv("FEDERATION_TOPOLOGY_TIMEOUT", "5.0"))


async def local_federation_read(subpath: str, principal: Principal) -> Response:
    """Derive the federation view for one read subpath from the sources that exist.

    Collector first, exactly as ``api_compat.trust_topology`` does, and for the
    same reason: it is the only thing in this estate that observes SPIFFE state
    on real workloads. A transport failure is an outage, not a contract
    violation, so it degrades to the tenant's own registry with every row
    labelled ``modeled`` and the cause carried on
    ``collectors.kubernetes.reason`` - it never substitutes a figure.

    A collector that answers with a payload this code cannot read is a different
    thing and is NOT degraded over: ``nodes`` is read defensively, and anything
    that is not a list yields no identities rather than invented ones.
    """
    topology: dict[str, Any] | None = None
    reason = ""
    try:
        async with httpx.AsyncClient(timeout=_TOPOLOGY_TIMEOUT) as client:
            response = await client.get(TRUST_TOPOLOGY_URL)
            response.raise_for_status()
            payload = response.json()
        if isinstance(payload, dict):
            topology = payload
        else:
            reason = (
                f"trust-topology collector returned {type(payload).__name__}, not a v1 object"
            )
    except (httpx.HTTPError, ValueError) as exc:
        logger.warning("federation state: trust-topology collector unreachable", exc_info=True)
        reason = f"trust-topology collector unreachable: {exc}"

    registry: list[Any] = []
    if topology is None:
        try:
            registry = list((await agents(principal)).agents)
        except Exception as exc:  # pragma: no cover - registry failure is reported, not hidden
            logger.warning("federation state: agent registry unavailable: %s", exc)
            reason = f"{reason}; agent registry also unavailable: {exc}"

    state = build_federation_state(
        tenant_id=principal.tenant,
        now=_now_iso(),
        topology=topology,
        topology_reason=reason,
        agents=registry,
    )
    return JSONResponse(status_code=200, content=project_subpath(state, subpath))


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
    principal: Principal = Depends(authenticated_principal),
) -> Response:
    """Serve the seven derived read subpaths locally; proxy everything else.

    The read split is deliberate and narrow. ``federation_state`` derives the
    measurable part of the federation view from the trust-topology collector
    (falling back, labelled ``modeled``, to the tenant's own registry) and
    refuses the rest per field. Every other method and subpath keeps the proxy
    - including its ``502 upstream_route_not_served`` - so adding a real
    federation handler to signal-ingest later needs no change here.
    """
    if request.method == "GET" and subpath.strip("/") in LOCAL_READ_SUBPATHS:
        return await local_federation_read(subpath.strip("/"), principal)
    return await proxy_federation_request(
        request, subpath, tenant_id=principal.tenant, principal=principal
    )


def install_federation_api(app: Any) -> None:
    """Mount the federation reverse proxy router on the FastAPI app."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is proxy_federation_route:
            return
    app.include_router(router)
