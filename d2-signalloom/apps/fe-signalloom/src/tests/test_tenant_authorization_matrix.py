"""SLAAT-P1-2: tenant authorization matrix and BOLA/IDOR probes.

``test_tenant_isolation.py`` already runs an exhaustive, route-derived
cross-tenant sweep for the five EAP routers (``test_every_eap_route_is_bound_to_the_callers_tenant``)
plus a ``DB_ROUTES`` sweep for ``api_compat``'s own compat-layer routes. This
file extends the SAME discipline -- never a hand-maintained list, always
derived from ``app.routes`` -- to the routers that sweep does not reach:
``routers/connectors.py``, ``routers/policies.py``, ``routers/policy_engine.py``,
``routers/federation.py``, ``routers/discovery.py``, ``routers/agents.py``,
``external_agent_registration.py`` and ``host_enrollment.py``.

Two layers:

1. A structural invariant -- every route in scope must have
   ``authenticated_principal`` or ``authenticated_tenant`` somewhere in its
   dependency tree. This is the single highest-leverage BOLA control: a new
   route added to any of these eight modules without an auth dependency is
   caught here, generically, the day it is added.
2. Concrete cross-tenant probes against the resource flows this card's
   objective names explicitly: connectors, agent listing/transition, and
   external-agent registration listing.
"""
from __future__ import annotations

import socket
import time
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from external_agent_registration import reset_external_agent_state
from host_enrollment import reset_host_enrollment_state
from main import app

TARGET_MODULES = frozenset(
    {
        "routers.connectors",
        "routers.policies",
        "routers.policy_engine",
        "routers.federation",
        "routers.discovery",
        "routers.agents",
        "external_agent_registration",
        "host_enrollment",
    }
)

_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ALICE, TENANT_A = "matrix-alice", "matrix-tenant-a"
BOB, TENANT_B = "matrix-bob", "matrix-tenant-b"


def _token(subject: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": "https://issuer.test/dex", "aud": "signalloom-api",
            "iat": now, "nbf": now, "exp": now + 300,
            "azp": "signalloom-dashboard", "sub": subject,
        },
        _SIGNING_KEY, algorithm="RS256", headers={"kid": "matrix-key", "typ": "JWT"},
    )


def _bearer(subject: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token(subject)}"}


class _JwkClient:
    def get_signing_key_from_jwt(self, token: str):
        from types import SimpleNamespace

        if jwt.get_unverified_header(token).get("kid") != "matrix-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=_SIGNING_KEY.public_key())


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {ALICE: TENANT_A, BOB: TENANT_B})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JwkClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    def _reject_network(*_a: Any, **_kw: Any) -> None:
        raise AssertionError("no external network in tests")

    monkeypatch.setattr(socket.socket, "connect", _reject_network)

    api_compat.reset_tenant_state(TENANT_A)
    api_compat.reset_tenant_state(TENANT_B)
    reset_external_agent_state()
    reset_host_enrollment_state()

    class _ReadyPool:
        async def close(self) -> None:
            pass

    set_pool_for_testing(_ReadyPool())
    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


# ---------------------------------------------------------------------------
# 1. Structural sweep: every in-scope route has a tenant-binding dependency
# ---------------------------------------------------------------------------


def _iter_api_routes(routes: Any) -> list[APIRoute]:
    from fastapi.routing import _IncludedRouter

    found: list[APIRoute] = []
    for route in routes:
        if isinstance(route, APIRoute):
            found.append(route)
        elif isinstance(route, _IncludedRouter):
            found.extend(_iter_api_routes(route.original_router.routes))
    return found


def _dependant_calls(dependant: Any, seen: set[int] | None = None) -> set[Any]:
    """Every callable anywhere in a route's dependency tree, including
    sub-dependencies of sub-dependencies."""
    seen = seen if seen is not None else set()
    calls: set[Any] = set()
    if id(dependant) in seen:
        return calls
    seen.add(id(dependant))
    if getattr(dependant, "call", None) is not None:
        calls.add(dependant.call)
    for sub in getattr(dependant, "dependencies", []) or []:
        calls |= _dependant_calls(sub, seen)
    return calls


_AUTH_DEPENDENCY_CALLABLES = {api_compat.authenticated_principal, api_compat.authenticated_tenant}


def _route_has_auth_dependency(route: APIRoute) -> bool:
    calls = _dependant_calls(route.dependant)
    return bool(calls & _AUTH_DEPENDENCY_CALLABLES)


#: Routes in scope that deliberately do NOT use
#: authenticated_principal/authenticated_tenant: the one-time external-host
#: enrollment token exchange authenticates via its own single-use bearer
#: token (SHA-256 hash compare-and-set), checked by hand inside
#: ``enroll_host_handler`` -- not a JWT. Mounted under three aliases
#: (``router``, ``api_router``, ``compat_router`` in host_enrollment.py).
#: See the dedicated CAS/replay suite in ``test_enrollment_cas_race_adversarial.py``.
_KNOWN_NON_JWT_ROUTES = frozenset(
    {
        ("POST", "/v1/external-agents/enroll"),
        ("POST", "/api/v1/external-agents/enroll"),
        ("POST", "/api/external-agents/enroll"),
    }
)

#: ``routers.policies.validate_policy_expression`` / ``evaluate_policies`` /
#: ``register_bundle`` / ``rollback_bundle`` declare NO auth dependency on
#: their own function signatures -- a structural gap by the sweep's own
#: measure. Runtime verification (``test_policies_router_own_routes_are_unreachable_dead_code``
#: below) shows they are NOT actually reachable: ``routers.policy_engine``'s
#: ``proxy_policies_route`` -- a wildcard ``/v1/policies/{subpath:path}`` with
#: ``Depends(authenticated_tenant)`` -- is registered earlier in
#: ``app.routes`` (via ``install_compatibility_api``) and matches first for
#: every concrete subpath including "validate", so Starlette never reaches
#: ``routers.policies``'s own exact-path route at all.
#:
#: This is NOT a vulnerability as deployed, but it IS a fragile accident, not
#: a declared contract: the only thing preventing exposure is include_router
#: *order* across three separate ``install_*_api`` functions plus an
#: identity-based dedup guard in ``install_policy_engine_api`` ("avoid
#: duplicate includes if already registered") that happens to fire before
#: ``routers.policies.router`` is ever separately included. Reordering
#: ``main.py``'s install calls, or loosening that dedup guard, would silently
#: unshadow four real, unauthenticated, tenant-touching routes (``evaluate``,
#: ``bundles``, ``rollback`` do read/write tenant policy state). MEDIUM
#: severity, Phase 2: either delete the dead ``routers.policies`` routes, or
#: give them their own explicit ``Depends(authenticated_tenant)`` so safety
#: does not depend on routing order.
_KNOWN_SHADOWED_DEAD_ROUTES = frozenset(
    {
        ("POST", "/v1/policies/validate"),
        ("POST", "/api/v1/policies/validate"),
    }
)


def _in_scope_routes() -> list[APIRoute]:
    """Routes in the SLAAT-P1-2 target modules, de-duplicated by
    (method, path): ``routers.agents``/``routers.discovery``/
    ``routers.policy_engine``/``routers.federation`` are each mounted twice on
    the live app -- once from ``api_compat.install_compatibility_api`` and
    once more from their own ``main.py``-level ``install_*_api`` call. Both
    copies share the identical ``APIRouter`` object (same dependant tree), so
    this is harmless double-registration, not two different behaviours to
    probe twice.
    """
    seen: set[tuple[str, str]] = set()
    out: list[APIRoute] = []
    for r in _iter_api_routes(app.routes):
        if getattr(r.endpoint, "__module__", "") not in TARGET_MODULES:
            continue
        for method in sorted(r.methods or ()):
            if method in ("HEAD", "OPTIONS"):
                continue
            key = (method, r.path)
            if key not in seen:
                seen.add(key)
                out.append(r)
    return out


IN_SCOPE_ROUTES = _in_scope_routes()


def test_scope_sweep_found_routes():
    assert len(IN_SCOPE_ROUTES) >= 15, len(IN_SCOPE_ROUTES)


@pytest.mark.parametrize(
    "route",
    IN_SCOPE_ROUTES,
    ids=[f"{sorted(r.methods or ())}:{r.path}" for r in IN_SCOPE_ROUTES],
)
def test_every_in_scope_route_has_a_tenant_binding_dependency(route: APIRoute):
    method = next(iter(sorted(route.methods or ())))
    key = (method, route.path)
    if key in _KNOWN_NON_JWT_ROUTES:
        pytest.skip("single-use bearer token scheme, not JWT -- see _KNOWN_NON_JWT_ROUTES")
    if key in _KNOWN_SHADOWED_DEAD_ROUTES:
        pytest.skip("structurally un-auth'd but unreachable dead code -- see _KNOWN_SHADOWED_DEAD_ROUTES")
    assert _route_has_auth_dependency(route), (
        f"{route.methods} {route.path} (module {route.endpoint.__module__}) has no "
        "authenticated_principal/authenticated_tenant dependency anywhere in its "
        "dependency tree -- this is a BOLA/anonymous-access gap"
    )


def test_non_jwt_exemption_routes_are_still_unauthenticated_reachable(client: TestClient):
    """A guard against ``_KNOWN_NON_JWT_ROUTES`` going stale: if a future fix
    adds JWT auth to the enrollment redemption endpoint, this fails loudly so
    the exemption gets removed from the sweep rather than left silently wrong.
    """
    for method, path in _KNOWN_NON_JWT_ROUTES:
        resp = client.request(method, path, json={})
        assert resp.status_code != 401 or resp.json().get("error_code") != "authentication_required", (
            f"{method} {path} now requires Bearer JWT auth -- remove it from _KNOWN_NON_JWT_ROUTES "
            "and let the sweep cover it directly"
        )


def test_policies_router_own_routes_are_unreachable_dead_code(client: TestClient):
    """Verifies the precise claim in ``_KNOWN_SHADOWED_DEAD_ROUTES``: an
    unauthenticated request to ``/api/v1/policies/validate`` is rejected with
    401 -- NOT because ``validate_policy_expression`` itself checks auth (it
    doesn't), but because ``routers.policy_engine.proxy_policies_route``'s
    wildcard, which DOES require ``authenticated_tenant``, is registered
    earlier in ``app.routes`` and matches first. If this ever starts
    returning anything other than 401 for a bare request, the shadowing has
    broken and the dead route has become live and unauthenticated --
    update both this test and the dossier finding immediately.
    """
    resp = client.post("/api/v1/policies/validate", json={"expression": "1 == 1"})
    assert resp.status_code == 401, (
        "routers.policies.validate_policy_expression appears reachable without "
        f"auth (got {resp.status_code}) -- the router-ordering shadow that made "
        "this safe has broken; see _KNOWN_SHADOWED_DEAD_ROUTES"
    )

    # Confirm it's the authenticated proxy answering, not a coincidental 401
    # from somewhere else: a request WITH a valid tenant token succeeds via
    # the proxy's own CEL validation.
    ok = client.post("/api/v1/policies/validate", json={"expression": "1 == 1"}, headers=_bearer(ALICE))
    assert ok.status_code in (200, 422), ok.text


# ---------------------------------------------------------------------------
# 2. Concrete cross-tenant probes
# ---------------------------------------------------------------------------


def test_connector_toggle_is_isolated_per_tenant_despite_identical_connector_ids(client: TestClient):
    """``conn-aws-01`` etc. are deterministic, identical IDs seeded for every
    tenant. Confirms the per-tenant dict lookup, not the ID, is what prevents
    cross-tenant mutation: bob toggling 'conn-aws-01' must never be visible
    in alice's own list.
    """
    alice_before = client.get("/api/v1/connectors", headers=_bearer(ALICE)).json()
    alice_status_before = next(c["status"] for c in alice_before["connectors"] if c["connector_id"] == "conn-aws-01")

    toggle_resp = client.post("/api/v1/connectors/conn-aws-01/toggle", json={}, headers=_bearer(BOB))
    assert toggle_resp.status_code == 200, toggle_resp.text

    alice_after = client.get("/api/v1/connectors", headers=_bearer(ALICE)).json()
    alice_status_after = next(c["status"] for c in alice_after["connectors"] if c["connector_id"] == "conn-aws-01")
    assert alice_status_after == alice_status_before, "bob's toggle leaked into alice's tenant-scoped connector state"


def test_agent_listing_is_isolated_per_tenant(client: TestClient):
    transition = client.post(
        "/api/v1/agents/matrix-shared-agent-id/transition",
        json={"to_state": "governed", "reason": "probe"},
        headers=_bearer(ALICE),
    )
    assert transition.status_code == 200, transition.text

    bob_list = client.get("/api/v1/agents", headers=_bearer(BOB)).json()
    bob_agent_ids = {a.get("agent_id") or a.get("id") for a in bob_list.get("agents", bob_list.get("items", []))}
    assert "matrix-shared-agent-id" not in bob_agent_ids, "bob's listing leaked alice's agent"


def test_cross_tenant_agent_transition_on_shared_id_does_not_mutate_the_other_tenants_record(client: TestClient):
    """Documents current behaviour for SLAAT-P1-2 rather than asserting a
    specific fix: alice transitions ``shared-probe-id`` to 'governed'; bob
    then transitions the SAME literal ``agent_id`` string. The in-memory
    store is keyed ``_AGENTS[tenant_id][agent_id]``, so this cannot read or
    overwrite alice's record -- bob's request, at worst, materialises his own
    independent record under the same ID (see ``routers/agents.py``'s
    "unknown id -> synthesize" fallback). Confirms no cross-tenant data
    leak; the dossier flags the synthesize-on-miss semantics as a separate,
    lower-severity design question for Phase 2.
    """
    agent_id = "shared-probe-id"
    r1 = client.post(
        f"/api/v1/agents/{agent_id}/transition",
        json={"to_state": "governed", "reason": "alice probe"},
        headers=_bearer(ALICE),
    )
    assert r1.status_code == 200, r1.text

    r2 = client.post(
        f"/api/v1/agents/{agent_id}/transition",
        json={"to_state": "suspended", "reason": "bob probe"},
        headers=_bearer(BOB),
    )
    assert r2.status_code in (200, 400, 409), r2.text

    # Alice's own view of the agent must be unaffected by bob's request.
    alice_list = client.get("/api/v1/agents", headers=_bearer(ALICE)).json()
    alice_agents = alice_list.get("agents", alice_list.get("items", []))
    alice_record = next((a for a in alice_agents if (a.get("agent_id") or a.get("id")) == agent_id), None)
    assert alice_record is not None, "alice's own record disappeared"
    assert alice_record.get("lifecycle_state") == "governed", (
        "bob's transition on the same literal agent_id mutated alice's tenant-scoped record"
    )


def test_external_agent_registration_listing_is_isolated_per_tenant(client: TestClient):
    register = client.post(
        "/api/v1/external-agents/registrations",
        json={"agent_id": "matrix-ext-agent-01", "host_id": "matrix-ext-host-01"},
        headers=_bearer(ALICE),
    )
    assert register.status_code == 201, register.text

    bob_list = client.get("/api/v1/external-agents/registrations", headers=_bearer(BOB))
    assert bob_list.status_code == 200, bob_list.text
    bob_ids = {r["agent_id"] for r in bob_list.json()["registrations"]}
    assert "matrix-ext-agent-01" not in bob_ids, "bob's registration listing leaked alice's external agent"

    bob_get = client.get("/api/v1/external-agents/matrix-ext-agent-01", headers=_bearer(BOB))
    assert bob_get.status_code in (403, 404), bob_get.text
