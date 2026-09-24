"""App-level default deny, tenant binding and tenant-key shape (EAPR-P2-1).

Three guarantees, each derived from ``app.routes`` rather than a hand list:

1. **Default deny.**  Every HTTP operation under ``/api`` and every websocket
   route refuses an anonymous caller with 401 — before validation (a 422 would
   mean the body was parsed for someone we do not know) and before any handler
   (a 403/404 would mean tenancy logic ran without a principal).  The only
   exemptions are ``ANONYMOUS_ROUTES``, each with a reason, each asserted to
   still exist.
2. **Tenant binding.**  Two tenants, alice (tenant-a) and bob (tenant-b), each
   create resources; neither can read, list or claim the other's.  Every
   negative is paired with the owner's positive in the same test so an empty
   or broken response cannot pass.
3. **Tenant key shape.**  A ``customer_hash`` that is not eight lowercase hex
   characters is 422 in bodies and in path parameters.

This module deliberately does NOT declare ``EAP_AUTHENTICATED`` and does not
use ``EAPClient`` for its negatives: the anonymous sweep runs with a raw
``TestClient`` so nothing in ``conftest.py`` can weaken it.  Authenticated
tests request the explicit ``eap_jwt_env`` fixture.
"""
from __future__ import annotations

import re
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

import pytest
from fastapi.routing import APIRoute, APIWebSocketRoute
from fastapi.testclient import TestClient
from starlette.routing import Mount, Route
from starlette.testclient import WebSocketDenialResponse
from starlette.websockets import WebSocketDisconnect

from conftest import EAP_OPERATOR, EAP_OPERATOR_ONLY_ROUTES, eap_bearer
from environment_routing import derive_customer_hash
from main import app

EAP_MODULES = frozenset(
    {"tenant_isolation", "scenario_seeding", "environment_routing", "environment_lifecycle", "webhook_triggers"}
)
EAP_PATH_PREFIXES = ("/api/v1/eap/", "/api/v1/environments", "/api/v1/webhooks")

#: Method/path pairs reachable without a principal, and why.  Minimal on purpose.
#:
#: OIDC callback: searched 2026-09-24 (``rg -i 'callback|oidc'`` over src/ and
#: ``app.routes``).  ``/auth/callback`` exists only as ``OIDC_CALLBACK_PATH`` in
#: environment_routing.py, a redirect URI built for each *tenant environment's*
#: mesh URL; it is not a route on this app, so it has no entry here.
#: ``test_no_oidc_callback_route_is_mounted`` keeps that claim honest.
ANONYMOUS_ROUTES: dict[tuple[str, str], str] = {
    ("GET", "/health"): "liveness probe for the kubelet and load balancer; returns a constant",
    ("GET", "/livez"): "process/event-loop probe; touches no dependency and returns a constant",
    ("GET", "/readyz"): "readiness probe; reports PostgreSQL/Redis state only, no tenant data",
    ("GET", "/openapi.json"): "FastAPI schema document; describes routes, carries no data",
    ("GET", "/docs"): "FastAPI Swagger UI shell; static HTML that loads /openapi.json",
    ("GET", "/docs/oauth2-redirect"): "Swagger UI OAuth2 redirect helper page; static HTML",
    ("GET", "/redoc"): "FastAPI ReDoc shell; static HTML that loads /openapi.json",
    ("GET", "/api/v1/external-agents/privacy"): (
        "frozen host privacy boundary contract, read by a host before it enrols; also on "
        "HostCredentialScopeMiddleware.ALLOWED_HOST_PATHS in host_credential.py"
    ),
}

#: Operations this app forwards to another service *without* checking the
#: principal itself: the ``Authorization`` header is copied onto the upstream
#: request and enforced there.  They are not anonymous by design, but from this
#: process's point of view an anonymous caller reaches the handler, so they are
#: listed separately from ``ANONYMOUS_ROUTES`` rather than laundered into it.
#: Every entry names the owner; none may be an EAP path.  Out of EAPR-P2-1's
#: scope (the card names the five EAP routers); recorded in the errata for the
#: Governor.
DELEGATED_AUTH_ROUTES: dict[tuple[str, str], str] = {
    ("POST", "/api/v1/telemetry/coding-agents"): (
        "SLCD-P5-1 BFF proxy (coding_agent_telemetry.py): Authorization forwarded to signal-ingest, "
        "which verifies it; no principal check in this process"
    ),
    ("GET", "/api/v1/telemetry/coding-agents"): "SLCD-P5-1 BFF proxy; auth enforced by signal-ingest",
    ("GET", "/api/v1/telemetry/coding-agents/aggregate"): "SLCD-P5-1 BFF proxy; auth enforced by signal-ingest",
    ("POST", "/api/v1/telemetry/coding-agents/ordering"): "SLCD-P5-1 BFF proxy; auth enforced by signal-ingest",
}

PROBE_DEADLINE_SECONDS = 3.0
NON_HEX_KEY = "ZZ/..zz!"
#: The same hostile key without the slash.  Starlette decodes ``%2F`` into the
#: path before routing, so the slash form lands on no route at all (404 at the
#: router, no handler reached); this single-segment form reaches route matching
#: and exercises the ``customer_hash`` validator itself.
NON_HEX_SEGMENT = "ZZ..zz!"


# ---------------------------------------------------------------------------
# Inventory — derived from app.routes, never hand-maintained.
# ---------------------------------------------------------------------------

def _module_of(route: Any) -> str:
    return getattr(getattr(route, "endpoint", None), "__module__", "") or ""


def _placeholder(name: str, convertor: Any) -> str:
    kind = type(convertor).__name__.lower()
    if "uuid" in kind or "uuid" in name:
        return str(uuid.UUID(int=0xDEADBEEF))
    if "int" in kind:
        return "1"
    if "hash" in name:
        return "0a1b2c3d"
    return "deadbeef"


def _concrete_path(route: Any) -> str:
    params = {
        name: _placeholder(name, conv) for name, conv in getattr(route, "param_convertors", {}).items()
    }
    return route.path_format.format(**params) if params else route.path_format


def _http_operations() -> list[tuple[str, str, APIRoute]]:
    ops = []
    for route in app.routes:
        if isinstance(route, APIRoute) and route.path.startswith("/api"):
            for method in sorted(route.methods or ()):
                if (method, route.path) not in ANONYMOUS_ROUTES and (method, route.path) not in DELEGATED_AUTH_ROUTES:
                    ops.append((method, route.path, route))
    return ops


HTTP_OPERATIONS = _http_operations()
WEBSOCKET_ROUTES = [r for r in app.routes if isinstance(r, APIWebSocketRoute)]
CUSTOMER_HASH_ROUTES = [
    (method, route.path, route)
    for route in app.routes
    if isinstance(route, APIRoute) and _module_of(route) in EAP_MODULES and "{customer_hash}" in route.path
    for method in sorted(route.methods or ())
]


def _run_with_deadline(fn: Callable[[], Any], label: str) -> Any:
    """Run ``fn`` on a daemon thread; a route that streams forever fails instead of hanging the suite."""
    box: dict[str, Any] = {}

    def target() -> None:
        try:
            box["value"] = fn()
        except BaseException as exc:  # noqa: BLE001 — re-raised on the test thread
            box["error"] = exc

    worker = threading.Thread(target=target, name=f"probe {label}", daemon=True)
    worker.start()
    worker.join(PROBE_DEADLINE_SECONDS)
    if worker.is_alive():
        pytest.fail(f"{label}: no response within {PROBE_DEADLINE_SECONDS}s — the handler was reached and is streaming")
    if "error" in box:
        raise box["error"]
    return box["value"]


# ---------------------------------------------------------------------------
# 1-3. Default deny
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("method", "path", "route"),
    HTTP_OPERATIONS,
    ids=[f"{m} {p}" for m, p, _ in HTTP_OPERATIONS],
)
def test_anonymous_request_to_every_api_operation_is_401(method: str, path: str, route: APIRoute) -> None:
    client = TestClient(app)
    url = _concrete_path(route)
    kwargs = {"json": {}} if method in {"POST", "PUT", "PATCH"} else {}
    response = _run_with_deadline(lambda: client.request(method, url, **kwargs), f"{method} {url}")
    assert "authorization" not in {k.lower() for k in response.request.headers}
    assert response.status_code == 401, (
        f"{method} {path} ({_module_of(route)}) answered {response.status_code} to an anonymous caller; "
        f"422 means validation ran before auth, 403/404 means a handler ran, 2xx/5xx means it was served"
    )


@pytest.mark.parametrize("route", WEBSOCKET_ROUTES, ids=[r.path for r in WEBSOCKET_ROUTES])
def test_anonymous_websocket_handshake_is_refused(route: APIWebSocketRoute) -> None:
    client = TestClient(app)
    url = _concrete_path(route)

    def handshake() -> str:
        try:
            with client.websocket_connect(url) as ws:
                return f"accepted, first frame {ws.receive_text()!r}"
        except WebSocketDenialResponse as denial:
            assert denial.status_code == 401, f"denied with {denial.status_code}, expected 401"
            return "denied 401"
        except WebSocketDisconnect as disconnect:
            assert disconnect.code == 1008, f"closed with {disconnect.code}, expected policy-violation 1008"
            return "closed 1008"

    outcome = _run_with_deadline(handshake, f"WS {url}")
    assert outcome in {"denied 401", "closed 1008"}, f"anonymous websocket {route.path}: {outcome}"


# ---------------------------------------------------------------------------
# 4. Guards on the sweep itself
# ---------------------------------------------------------------------------

def test_guard_sweep_covers_the_eap_routers() -> None:
    swept = [p for _, p, r in HTTP_OPERATIONS if _module_of(r) in EAP_MODULES]
    swept += [r.path for r in WEBSOCKET_ROUTES if _module_of(r) in EAP_MODULES]
    assert len(swept) >= 23, f"only {len(swept)} EAP routes swept — has a router stopped being mounted?"
    assert {_module_of(r) for _, _, r in HTTP_OPERATIONS} >= EAP_MODULES, "an EAP module contributes no swept route"


def test_guard_every_anonymous_entry_still_exists() -> None:
    live = {
        (method, route.path)
        for route in app.routes
        if isinstance(route, (APIRoute, Route))
        for method in (route.methods or ())
    }
    stale = sorted(set(ANONYMOUS_ROUTES) - live)
    assert not stale, f"ANONYMOUS_ROUTES names routes the app no longer has: {stale}"
    assert all(reason.strip() for reason in ANONYMOUS_ROUTES.values()), "every exemption needs a reason"


def test_guard_no_eap_path_is_anonymous() -> None:
    leaked = sorted(key for key in ANONYMOUS_ROUTES if key[1].startswith(EAP_PATH_PREFIXES))
    assert not leaked, f"EAP paths must never be anonymous: {leaked}"
    delegated = sorted(key for key in DELEGATED_AUTH_ROUTES if key[1].startswith(EAP_PATH_PREFIXES))
    assert not delegated, f"EAP paths must never delegate their principal check: {delegated}"


def test_guard_delegated_auth_routes_are_exactly_the_telemetry_proxy() -> None:
    """The delegated list may only ever name the SLCD proxy module, and every entry must still exist."""
    by_key = {
        (method, route.path): route
        for route in app.routes
        if isinstance(route, APIRoute)
        for method in (route.methods or ())
    }
    stale = sorted(set(DELEGATED_AUTH_ROUTES) - set(by_key))
    assert not stale, f"DELEGATED_AUTH_ROUTES names routes the app no longer has: {stale}"
    modules = {_module_of(by_key[key]) for key in DELEGATED_AUTH_ROUTES}
    assert modules == {"coding_agent_telemetry"}, f"delegated-auth exemptions outside the SLCD proxy: {modules}"
    assert all(reason.strip() for reason in DELEGATED_AUTH_ROUTES.values()), "every exemption needs a reason"
    proxied = {key for key, route in by_key.items() if _module_of(route) == "coding_agent_telemetry"}
    assert proxied == set(DELEGATED_AUTH_ROUTES), (
        f"the proxy module gained or lost operations; the list must match exactly: {sorted(proxied ^ set(DELEGATED_AUTH_ROUTES))}"
    )


@pytest.mark.parametrize(
    ("method", "path"), sorted(DELEGATED_AUTH_ROUTES), ids=[f"{m} {p}" for m, p in sorted(DELEGATED_AUTH_ROUTES)]
)
def test_guard_delegated_auth_routes_reach_the_upstream_without_a_principal_check(
    method: str, path: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Documents the shape the exemption covers: an anonymous call is forwarded, not refused here.

    The upstream is pointed at a closed local port (no DNS, no network), so the
    proxy answers 502 at once — proof the handler ran for a caller this process
    never identified.  If this ever turns into a 401 the route has gained a
    local principal check and belongs in the default-deny sweep instead.
    """
    import coding_agent_telemetry

    monkeypatch.setattr(coding_agent_telemetry, "_SIGNAL_INGEST_URL", "http://127.0.0.1:9")
    kwargs = {"json": {}} if method == "POST" else {}
    response = _run_with_deadline(lambda: TestClient(app).request(method, path, **kwargs), f"{method} {path}")
    assert response.status_code == 502, (
        f"{method} {path} answered {response.status_code}; 401 means it now checks the principal locally "
        f"and must leave DELEGATED_AUTH_ROUTES"
    )
    assert response.json()["error"]["code"] == "upstream_unavailable"


class _RecordingUpstream(BaseHTTPRequestHandler):
    """A stand-in signal-ingest: records every request's headers and answers 401."""

    seen: list[dict[str, str]] = []

    def _answer(self) -> None:
        self.seen.append({k.lower(): v for k, v in self.headers.items()})
        if "content-length" in self.headers:
            self.rfile.read(int(self.headers["content-length"]))
        body = b'{"error":{"code":"unauthenticated","message":"stub upstream refused"}}'
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _answer
    do_POST = _answer

    def log_message(self, *_: Any) -> None:  # keep pytest output clean
        return


@pytest.fixture
def recording_upstream(monkeypatch: pytest.MonkeyPatch):
    import coding_agent_telemetry

    _RecordingUpstream.seen = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RecordingUpstream)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setattr(coding_agent_telemetry, "_SIGNAL_INGEST_URL", f"http://127.0.0.1:{server.server_port}")
    try:
        yield _RecordingUpstream
    finally:
        server.shutdown()
        server.server_close()


def test_guard_delegated_auth_is_really_delegated(recording_upstream) -> None:
    """The exemption's reason is a claim; this is its proof.

    Against a recording upstream: the anonymous call is forwarded with no
    Authorization and the upstream's 401 comes back unrewritten; a bearer is
    forwarded byte-for-byte; a forged identity header never reaches the
    upstream because the strip middleware ran first.
    """
    client = TestClient(app)
    anonymous = client.get("/api/v1/telemetry/coding-agents")
    assert anonymous.status_code == 401
    assert anonymous.json()["error"]["code"] == "unauthenticated", "the upstream verdict must propagate, not be rewritten"
    assert "authorization" not in recording_upstream.seen[-1]

    token = "Bearer not-a-real-token.exact.bytes"
    forwarded = client.get(
        "/api/v1/telemetry/coding-agents",
        headers={"Authorization": token, "X-SPIFFE-ID": "spiffe://forged/ns/x/sa/y", "X-Tenant-Id": "tenant-b"},
    )
    assert forwarded.status_code == 401  # the stub refuses everything; the point is what it received
    upstream_saw = recording_upstream.seen[-1]
    assert upstream_saw.get("authorization") == token, "Authorization must be forwarded byte-for-byte"
    assert "x-spiffe-id" not in upstream_saw and "x-tenant-id" not in upstream_saw, (
        "a forged identity header reached the upstream; the strip middleware must run before the proxy"
    )


#: The EAP surface, pinned.  ``test_guard_sweep_covers_the_eap_routers`` has a
#: floor; a floor lets routes vanish (an import error in one router, a mount
#: dropped by mistake) while the sweep stays green.  Set equality does not.  A
#: new or removed EAP route must change this list on the record.
EXPECTED_EAP_OPERATIONS: frozenset[tuple[str, str]] = frozenset(
    {
        ("DELETE", "/api/v1/eap/tenants/{customer_hash}"),
        ("GET", "/api/v1/eap/lifecycle/active"),
        ("GET", "/api/v1/eap/lifecycle/audit-events"),
        ("GET", "/api/v1/eap/lifecycle/environments/{customer_hash}"),
        ("GET", "/api/v1/eap/lifecycle/metrics"),
        ("GET", "/api/v1/eap/lifecycle/reaper/dlq"),
        ("GET", "/api/v1/eap/lifecycle/reaper/status"),
        ("GET", "/api/v1/eap/scenarios/events/{customer_hash}"),
        ("GET", "/api/v1/eap/scenarios/events/{customer_hash}/stream"),
        ("GET", "/api/v1/eap/scenarios/history"),
        ("GET", "/api/v1/eap/tenants"),
        ("GET", "/api/v1/eap/tenants/{customer_hash}"),
        ("GET", "/api/v1/eap/tenants/{customer_hash}/manifests"),
        ("GET", "/api/v1/eap/tenants/{customer_hash}/spire-entry"),
        ("GET", "/api/v1/environments/"),
        ("GET", "/api/v1/environments/{environment_id}"),
        ("GET", "/api/v1/environments/{environment_id}/probe"),
        ("POST", "/api/v1/eap/lifecycle/environments/{customer_hash}/activity"),
        ("POST", "/api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat"),
        ("POST", "/api/v1/eap/lifecycle/reap-now"),
        ("POST", "/api/v1/eap/lifecycle/reaper/dlq/clear"),
        ("POST", "/api/v1/eap/lifecycle/reaper/pause"),
        ("POST", "/api/v1/eap/lifecycle/reaper/resume"),
        ("POST", "/api/v1/eap/lifecycle/register"),
        ("POST", "/api/v1/eap/scenarios/execute"),
        ("POST", "/api/v1/eap/tenants"),
        ("POST", "/api/v1/eap/tenants/{customer_hash}/transit/decrypt"),
        ("POST", "/api/v1/eap/tenants/{customer_hash}/transit/encrypt"),
        ("POST", "/api/v1/environments/provision"),
        ("POST", "/api/v1/environments/resolve-domain"),
        ("POST", "/api/v1/environments/{environment_id}/extend"),
        ("POST", "/api/v1/environments/{environment_id}/teardown"),
        ("POST", "/api/v1/webhooks/generic"),
        ("POST", "/api/v1/webhooks/github"),
        ("WS", "/api/v1/environments/{environment_id}/telemetry"),
    }
)


def test_guard_eap_inventory_is_exactly_the_pinned_set() -> None:
    live = {(m, p) for m, p, r in HTTP_OPERATIONS if _module_of(r) in EAP_MODULES}
    live |= {("WS", r.path) for r in WEBSOCKET_ROUTES if _module_of(r) in EAP_MODULES}
    missing = sorted(EXPECTED_EAP_OPERATIONS - live)
    unexpected = sorted(live - EXPECTED_EAP_OPERATIONS)
    assert not missing, f"EAP operations vanished from the sweep (unmounted, exempted, or import error): {missing}"
    assert not unexpected, f"new EAP operations must be added to EXPECTED_EAP_OPERATIONS on the record: {unexpected}"
    # The customer_hash validator sweep must cover every pinned hash-addressed operation, so an
    # empty or shrunken CUSTOMER_HASH_ROUTES cannot pass by having nothing to probe.
    pinned_hash_ops = {(m, p) for m, p in EXPECTED_EAP_OPERATIONS if "{customer_hash}" in p}
    assert {(m, p) for m, p, _ in CUSTOMER_HASH_ROUTES} == pinned_hash_ops
    assert len(pinned_hash_ops) == 11


#: Process-wide reaper controls: one daemon serves every tenant, so these cannot
#: be bound to a tenant and are bound to the operator role instead (shared list in conftest).
OPERATOR_ONLY_ROUTES = EAP_OPERATOR_ONLY_ROUTES


@pytest.mark.parametrize(
    ("method", "path"), sorted(OPERATOR_ONLY_ROUTES), ids=[f"{m} {p}" for m, p in sorted(OPERATOR_ONLY_ROUTES)]
)
def test_reaper_controls_are_operator_only(method: str, path: str, eap_jwt_env) -> None:
    """A tenant principal cannot pause, force, or inspect the reaper that serves every tenant.

    alice (tenant-a) and bob (tenant-b) get 403 ``superadmin_required`` and the
    daemon's pause flag does not move; the operator gets 200 on the same call
    (positive control), so the refusal is the role check and not a dead route.
    """
    from environment_lifecycle import GLOBAL_REAPER_DAEMON

    client = TestClient(app)
    was_paused = GLOBAL_REAPER_DAEMON.is_paused
    for tenant_subject in ("alice", "bob"):
        refused = client.request(method, path, headers=eap_bearer(tenant_subject))
        assert refused.status_code == 403, f"{tenant_subject}: {method} {path} answered {refused.status_code}"
        assert refused.json()["error"]["code"] == "superadmin_required"
    assert GLOBAL_REAPER_DAEMON.is_paused == was_paused, "a tenant call moved the process-wide pause flag"
    allowed = client.request(method, path, headers=eap_bearer(EAP_OPERATOR))
    assert allowed.status_code == 200, f"positive control: operator got {allowed.status_code} on {method} {path}: {allowed.text}"
    if path.endswith("/pause"):
        client.request("POST", "/api/v1/eap/lifecycle/reaper/resume", headers=eap_bearer(EAP_OPERATOR))


def test_guard_operator_only_routes_carry_the_superadmin_gate_structurally() -> None:
    """Each operator-only handler declares the require_superadmin dependency, so the 403 above is not a coincidence."""
    from superadmin import require_superadmin

    def declares_gate(route: APIRoute) -> bool:
        return any(d.call is require_superadmin for d in route.dependant.dependencies)

    by_key = {(m, r.path): r for r in app.routes if isinstance(r, APIRoute) for m in (r.methods or ())}
    ungated = sorted(key for key in OPERATOR_ONLY_ROUTES if not declares_gate(by_key[key]))
    assert ungated == [], f"operator-only routes without require_superadmin: {ungated}"
    gated_elsewhere = sorted(
        key for key, r in by_key.items() if _module_of(r) in EAP_MODULES and declares_gate(r) and key not in OPERATOR_ONLY_ROUTES
    )
    assert gated_elsewhere == [], f"EAP routes gained the operator gate without being listed: {gated_elsewhere}"


def test_guard_no_route_escapes_the_inventory() -> None:
    """Nothing is mounted where the sweep cannot see it, and every non-API route is a listed exemption."""
    mounts = [r.path for r in app.routes if isinstance(r, Mount)]
    assert mounts == [], f"sub-applications are invisible to the sweep and must not exist: {mounts}"
    unknown = sorted(
        (method, route.path)
        for route in app.routes
        if isinstance(route, Route) and not isinstance(route, APIRoute)
        for method in (route.methods or ())
        if method != "HEAD" and (method, route.path) not in ANONYMOUS_ROUTES
    )
    assert unknown == [], f"plain Starlette routes outside ANONYMOUS_ROUTES: {unknown}"
    kinds = {type(r).__name__ for r in app.routes}
    assert kinds <= {"Route", "APIRoute", "APIWebSocketRoute"}, f"unexpected route kinds: {kinds}"


@pytest.mark.parametrize(
    ("method", "path", "route"),
    [(m, p, r) for m, p, r in HTTP_OPERATIONS if _module_of(r) in EAP_MODULES and m == "GET"],
    ids=[f"HEAD/OPTIONS {p}" for m, p, r in HTTP_OPERATIONS if _module_of(r) in EAP_MODULES and m == "GET"],
)
def test_anonymous_head_and_options_on_eap_routes_never_reach_a_handler(method: str, path: str, route: APIRoute) -> None:
    """No CORS or automatic HEAD path answers ahead of the auth dependency (401 or 405, never 2xx)."""
    del method
    client = TestClient(app)
    url = _concrete_path(route)
    for probe in ("HEAD", "OPTIONS"):
        response = _run_with_deadline(
            lambda: client.request(probe, url, headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "GET"}),
            f"{probe} {url}",
        )
        assert response.status_code in {401, 405}, f"{probe} {path} answered {response.status_code} anonymously"
        assert "access-control-allow-origin" not in {k.lower() for k in response.headers}


def test_no_oidc_callback_route_is_mounted() -> None:
    callbacks = [r.path for r in app.routes if re.search(r"callback|oidc", r.path, re.IGNORECASE)]
    assert callbacks == [], f"an OIDC callback is now mounted and needs an ANONYMOUS_ROUTES decision: {callbacks}"


@pytest.mark.parametrize(("method", "path"), sorted(ANONYMOUS_ROUTES), ids=[f"{m} {p}" for m, p in sorted(ANONYMOUS_ROUTES)])
def test_guard_anonymous_routes_are_served_without_a_token(method: str, path: str) -> None:
    response = TestClient(app).request(method, path)
    assert response.status_code != 401, f"{method} {path} is exempt but demanded a token"
    if path in {"/health", "/livez"}:
        assert response.status_code == 200
    elif path == "/readyz":
        assert response.status_code in {200, 503}, "readyz without a database is 503, never an auth failure"
    else:
        assert response.status_code == 200


# ---------------------------------------------------------------------------
# 5. Tenant binding — two tenants
# ---------------------------------------------------------------------------

def _seed_tenant(client: TestClient, subject: str, company: str) -> dict[str, str]:
    """Create an environment, a boundary, a scenario run and a lifecycle lease for ``company`` as ``subject``."""
    headers = eap_bearer(subject)
    env = client.post("/api/v1/environments/provision", json={"company_name": company}, headers=headers)
    assert env.status_code == 201, env.text
    body = env.json()
    assert body["customer_hash"] == derive_customer_hash(company)
    for path in ("/api/v1/eap/tenants", "/api/v1/eap/scenarios/execute", "/api/v1/eap/lifecycle/register"):
        created = client.post(path, json={"company_name": company}, headers=headers)
        assert created.status_code == 201, f"{subject} {path}: {created.status_code} {created.text}"
        assert created.json()["customer_hash"] == body["customer_hash"]
    return {"id": body["id"], "hash": body["customer_hash"], "company": company}


@pytest.fixture
def two_tenants(eap_jwt_env, fresh_tenant_ownership) -> dict[str, Any]:
    client = TestClient(app)
    suffix = uuid.uuid4().hex[:8]
    alice = _seed_tenant(client, "alice", f"alicecorp-{suffix}")
    bob = _seed_tenant(client, "bob", f"bobcorp-{suffix}")
    assert alice["hash"] != bob["hash"]
    return {"client": client, "alice": alice, "bob": bob}


def _hashes_in(rows: list[dict[str, Any]]) -> list[str]:
    return [row["customer_hash"] for row in rows]


def test_tenant_binding_environment_read_is_404_for_the_other_tenant(two_tenants) -> None:
    client, alice = two_tenants["client"], two_tenants["alice"]
    stolen = client.get(f"/api/v1/environments/{alice['id']}", headers=eap_bearer("bob"))
    assert stolen.status_code == 404
    assert alice["hash"] not in stolen.text
    own = client.get(f"/api/v1/environments/{alice['id']}", headers=eap_bearer("alice"))
    assert own.status_code == 200
    assert own.json()["customer_hash"] == alice["hash"]


def test_tenant_binding_history_is_filtered(two_tenants) -> None:
    client, alice, bob = two_tenants["client"], two_tenants["alice"], two_tenants["bob"]
    for me, them in (("bob", alice), ("alice", bob)):
        mine = two_tenants[me]
        response = client.get("/api/v1/eap/scenarios/history", headers=eap_bearer(me))
        assert response.status_code == 200
        hashes = _hashes_in(response.json())
        assert hashes.count(them["hash"]) == 0, f"{me} sees the other tenant's scenario history"
        assert hashes.count(mine["hash"]) >= 1, f"{me} cannot see their own scenario history"


def test_tenant_binding_tenant_boundary_read_is_404_for_the_other_tenant(two_tenants) -> None:
    client, alice = two_tenants["client"], two_tenants["alice"]
    stolen = client.get(f"/api/v1/eap/tenants/{alice['hash']}", headers=eap_bearer("bob"))
    assert stolen.status_code == 404
    own = client.get(f"/api/v1/eap/tenants/{alice['hash']}", headers=eap_bearer("alice"))
    assert own.status_code == 200
    assert own.json()["customer_hash"] == alice["hash"]


def test_tenant_binding_lifecycle_active_is_filtered(two_tenants) -> None:
    client, alice, bob = two_tenants["client"], two_tenants["alice"], two_tenants["bob"]
    for me, them in (("bob", alice), ("alice", bob)):
        response = client.get("/api/v1/eap/lifecycle/active", headers=eap_bearer(me))
        assert response.status_code == 200
        hashes = _hashes_in(response.json())
        assert them["hash"] not in hashes, f"{me} sees the other tenant's lifecycle lease"
        assert two_tenants[me]["hash"] in hashes, f"{me} cannot see their own lifecycle lease"
    stolen = client.get(f"/api/v1/eap/lifecycle/environments/{alice['hash']}", headers=eap_bearer("bob"))
    assert stolen.status_code == 404
    own = client.get(f"/api/v1/eap/lifecycle/environments/{alice['hash']}", headers=eap_bearer("alice"))
    assert own.status_code == 200


def test_tenant_binding_execute_rejects_a_hash_owned_by_another_tenant(two_tenants) -> None:
    client, alice, bob = two_tenants["client"], two_tenants["alice"], two_tenants["bob"]
    hijack = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"company_name": bob["company"], "customer_hash": alice["hash"]},
        headers=eap_bearer("bob"),
    )
    assert hijack.status_code == 403
    own = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"company_name": alice["company"], "customer_hash": alice["hash"]},
        headers=eap_bearer("alice"),
    )
    assert own.status_code == 201
    assert own.json()["customer_hash"] == alice["hash"]


def test_tenant_binding_list_environments_is_filtered(two_tenants) -> None:
    client, alice, bob = two_tenants["client"], two_tenants["alice"], two_tenants["bob"]
    for me, them in (("bob", alice), ("alice", bob)):
        response = client.get("/api/v1/environments/", headers=eap_bearer(me))
        assert response.status_code == 200
        rows = response.json()
        assert them["id"] not in [row["id"] for row in rows]
        assert them["hash"] not in _hashes_in(rows)
        assert two_tenants[me]["id"] in [row["id"] for row in rows]


# ---------------------------------------------------------------------------
# 6. Non-hex tenant key
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "path",
    ["/api/v1/eap/scenarios/execute", "/api/v1/eap/tenants", "/api/v1/eap/lifecycle/register"],
)
def test_non_hex_customer_hash_in_a_body_is_422(eap_jwt_env, fresh_tenant_ownership, path: str) -> None:
    client = TestClient(app)
    company = f"nonhex-{uuid.uuid4().hex[:8]}"
    refused = client.post(path, json={"company_name": company, "customer_hash": NON_HEX_KEY}, headers=eap_bearer("alice"))
    assert refused.status_code == 422
    assert fresh_tenant_ownership.hashes_for("tenant-a") == set(), "a refused key must not be claimed"
    accepted = client.post(path, json={"company_name": company}, headers=eap_bearer("alice"))
    assert accepted.status_code == 201, "positive control: the same body without the hostile key is accepted"


def _body_for(path: str, owned_hash: str, client: TestClient) -> dict[str, Any] | None:
    """A body the handler accepts, so the positive control isolates the path parameter."""
    if path.endswith("/transit/encrypt"):
        return {"plaintext": "aGVsbG8="}
    if path.endswith("/transit/decrypt"):
        sealed = client.post(
            f"/api/v1/eap/tenants/{owned_hash}/transit/encrypt", json={"plaintext": "aGVsbG8="}, headers=eap_bearer("alice")
        )
        assert sealed.status_code == 200, sealed.text
        return {"ciphertext": sealed.json()["ciphertext"]}
    return {}


def _call(client: TestClient, method: str, url: str, body: dict[str, Any] | None) -> Any:
    kwargs: dict[str, Any] = {"headers": eap_bearer("alice")}
    if method in {"POST", "PUT", "PATCH"}:
        kwargs["json"] = body
    return _run_with_deadline(lambda: client.request(method, url, **kwargs), f"{method} {url}")


@pytest.mark.parametrize(
    ("method", "path", "route"),
    CUSTOMER_HASH_ROUTES,
    ids=[f"{m} {p}" for m, p, _ in CUSTOMER_HASH_ROUTES],
)
def test_non_hex_customer_hash_in_a_path_is_422(eap_jwt_env, fresh_tenant_ownership, method: str, path: str, route: APIRoute) -> None:
    client = TestClient(app)
    company = f"nonhexpath-{uuid.uuid4().hex[:8]}"
    headers = eap_bearer("alice")
    for seed in ("/api/v1/eap/tenants", "/api/v1/eap/scenarios/execute", "/api/v1/eap/lifecycle/register"):
        assert client.post(seed, json={"company_name": company}, headers=headers).status_code == 201
    owned = derive_customer_hash(company)
    body = _body_for(path, owned, client)

    def url_for(key: str) -> str:
        url = path.replace("{customer_hash}", urllib.parse.quote(key, safe=""))
        return url + ("?limit=1" if path.endswith("/stream") else "")

    refused = _call(client, method, url_for(NON_HEX_SEGMENT), body)
    assert refused.status_code == 422, f"{method} {path} with a non-hex key answered {refused.status_code}"

    # The brief's literal key carries a '/'.  Starlette decodes %2F before
    # routing, so it matches no route; what matters is that no handler runs.
    slashed = _call(client, method, url_for(NON_HEX_KEY), body)
    assert slashed.status_code in {404, 422}, f"{method} {path} with {NON_HEX_KEY!r} answered {slashed.status_code}"

    # Positive control: the same route, body and caller with a valid owned key is not 422.
    control = _call(client, method, url_for(owned), body)
    assert control.status_code != 422, f"positive control: {method} {path} rejected a valid owned key ({control.text})"
    assert control.status_code < 500
