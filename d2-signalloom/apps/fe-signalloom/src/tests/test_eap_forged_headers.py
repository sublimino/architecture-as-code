"""Forged identity headers never change who the caller is (EAPR-P2-1).

The credential doctrine: tenancy comes from the verified bearer token only.
``main.IdentityHeaderStripMiddleware`` drops ``x-spiffe-*``, ``x-tenant-*``,
``x-principal-*`` and ``x-forwarded-user`` for http and websocket scopes, and no
EAP handler reads an identity header.  These tests attack both halves: a
legitimate token for one tenant plus headers claiming the other tenant, a
forged header with no token at all, and a direct look at what a handler
receives.

Nothing here bypasses authentication: every authenticated test asks for the
explicit ``eap_jwt_env`` fixture and presents a real RS256 token, and two-tenant
tests use ``fresh_tenant_ownership``.  Every negative is paired with the
owner's positive so an empty or broken response cannot pass.
"""
from __future__ import annotations

import base64
import threading
import uuid
from typing import Any, Callable

import pytest
from fastapi import Request
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from conftest import EAPClient, eap_bearer
from environment_routing import derive_customer_hash
from main import app
from tenant_isolation import get_tenant_spiffe_id

EAP_MODULES = frozenset(
    {"tenant_isolation", "scenario_seeding", "environment_routing", "environment_lifecycle", "webhook_triggers"}
)
PROBE_DEADLINE_SECONDS = 3.0
ECHO_PATH = "/__eapr_p2_1_echo_headers"


def _forged_as(victim_hash: str, victim_subject: str = "alice") -> dict[str, str]:
    """Every identity header a proxy might be trusted for, naming ``victim_hash``."""
    return {
        "X-SPIFFE-ID": get_tenant_spiffe_id(victim_hash),
        "X-Tenant-Id": victim_hash,
        "X-Forwarded-User": victim_subject,
        "X-Principal-Sub": victim_subject,
    }


def _run_with_deadline(fn: Callable[[], Any], label: str) -> Any:
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
        pytest.fail(f"{label}: no response within {PROBE_DEADLINE_SECONDS}s — a forged caller reached a stream")
    if "error" in box:
        raise box["error"]
    return box["value"]


def _seed_tenant(client: TestClient, subject: str, company: str) -> dict[str, str]:
    headers = eap_bearer(subject)
    env = client.post("/api/v1/environments/provision", json={"company_name": company}, headers=headers)
    assert env.status_code == 201, env.text
    body = env.json()
    for path in ("/api/v1/eap/tenants", "/api/v1/eap/scenarios/execute", "/api/v1/eap/lifecycle/register"):
        created = client.post(path, json={"company_name": company}, headers=headers)
        assert created.status_code == 201, f"{subject} {path}: {created.status_code} {created.text}"
    return {"id": body["id"], "hash": body["customer_hash"], "company": company}


@pytest.fixture
def two_tenants(eap_jwt_env, fresh_tenant_ownership) -> dict[str, Any]:
    client = TestClient(app)
    suffix = uuid.uuid4().hex[:8]
    alice = _seed_tenant(client, "alice", f"forged-alicecorp-{suffix}")
    bob = _seed_tenant(client, "bob", f"forged-bobcorp-{suffix}")
    assert alice["hash"] != bob["hash"]
    return {"client": client, "alice": alice, "bob": bob}


# ---------------------------------------------------------------------------
# 1-2. Transit keys
# ---------------------------------------------------------------------------

def test_forged_spiffe_header_with_alices_token_cannot_decrypt_bobs_data(eap_jwt_env, fresh_tenant_ownership) -> None:
    client = TestClient(app)
    company = f"forged-bobcorp-{uuid.uuid4().hex[:8]}"
    boundary = client.post("/api/v1/eap/tenants", json={"company_name": company}, headers=eap_bearer("bob"))
    assert boundary.status_code == 201, boundary.text
    bob_hash = boundary.json()["customer_hash"]
    assert bob_hash == derive_customer_hash(company)

    secret = f"bob-secret-{uuid.uuid4().hex}".encode()
    secret_b64 = base64.b64encode(secret).decode()
    sealed = client.post(
        f"/api/v1/eap/tenants/{bob_hash}/transit/encrypt", json={"plaintext": secret_b64}, headers=eap_bearer("bob")
    )
    assert sealed.status_code == 200, sealed.text
    ciphertext = sealed.json()["ciphertext"]

    forged = {
        **eap_bearer("alice"),
        "X-SPIFFE-ID": f"spiffe://signalloom.demo/ns/eap-{bob_hash}/sa/tenant-app",
        "X-Tenant-Id": bob_hash,
    }
    stolen = client.post(f"/api/v1/eap/tenants/{bob_hash}/transit/decrypt", json={"ciphertext": ciphertext}, headers=forged)
    assert stolen.status_code == 404
    assert secret_b64 not in stolen.text and secret.decode() not in stolen.text

    own = client.post(
        f"/api/v1/eap/tenants/{bob_hash}/transit/decrypt", json={"ciphertext": ciphertext}, headers=eap_bearer("bob")
    )
    assert own.status_code == 200
    assert base64.b64decode(own.json()["plaintext"]) == secret


def test_forged_header_without_a_bearer_is_401(eap_jwt_env, fresh_tenant_ownership) -> None:
    client = TestClient(app)
    company = f"forged-bobcorp-{uuid.uuid4().hex[:8]}"
    boundary = client.post("/api/v1/eap/tenants", json={"company_name": company}, headers=eap_bearer("bob"))
    assert boundary.status_code == 201
    bob_hash = boundary.json()["customer_hash"]
    forged = {
        "X-SPIFFE-ID": f"spiffe://signalloom.demo/ns/eap-{bob_hash}/sa/tenant-app",
        "X-Tenant-Id": bob_hash,
    }
    decrypt = client.post(f"/api/v1/eap/tenants/{bob_hash}/transit/decrypt", json={"ciphertext": "vault:v1:AAAA"}, headers=forged)
    assert decrypt.status_code == 401
    read = client.get(f"/api/v1/eap/tenants/{bob_hash}", headers=forged)
    assert read.status_code == 401
    # Positive control: the owner's token alone reads it.
    assert client.get(f"/api/v1/eap/tenants/{bob_hash}", headers=eap_bearer("bob")).status_code == 200


# ---------------------------------------------------------------------------
# 3. Every EAP GET, forged as the other tenant
# ---------------------------------------------------------------------------

EAP_GET_ROUTES = [
    route
    for route in app.routes
    if isinstance(route, APIRoute) and "GET" in (route.methods or ()) and route.endpoint.__module__ in EAP_MODULES
]


def test_forged_headers_never_change_the_resolved_tenant_on_any_eap_route(two_tenants) -> None:
    client, alice, bob = two_tenants["client"], two_tenants["alice"], two_tenants["bob"]
    forged_bob = {**eap_bearer("bob"), **_forged_as(alice["hash"])}

    listings = [r for r in EAP_GET_ROUTES if not r.param_convertors]
    addressed = [r for r in EAP_GET_ROUTES if r.param_convertors]
    assert len(listings) >= 4 and len(addressed) >= 5, "EAP GET inventory shrank — is a router unmounted?"

    tenant_listings = []
    for route in listings:
        response = client.get(route.path, headers=forged_bob)
        assert response.status_code == 200, f"{route.path}: {response.status_code}"
        assert alice["hash"] not in response.text, f"{route.path} returned alice's data to bob with forged headers"
        if bob["hash"] in response.text:
            tenant_listings.append(route.path)
    # The listings that are tenant-scoped must show bob its own rows, so an empty body cannot pass.
    for expected in ("/api/v1/eap/tenants", "/api/v1/eap/lifecycle/active", "/api/v1/eap/scenarios/history", "/api/v1/environments/"):
        assert expected in tenant_listings, f"{expected} did not return bob's own hash — forged headers changed the tenant"

    for route in addressed:
        params = {"customer_hash": alice["hash"], "environment_id": alice["id"]}
        url = route.path_format.format(**{name: params[name] for name in route.param_convertors})
        if url.endswith("/stream"):
            url += "?limit=1"
        response = _run_with_deadline(lambda u=url: client.get(u, headers=forged_bob), f"GET {url}")
        assert response.status_code == 404, f"{route.path}: bob + forged headers got {response.status_code}"
        assert alice["hash"] not in response.text, f"{route.path}: the 404 body names alice's hash"
        # Positive control: alice's own token reaches it.
        own = _run_with_deadline(lambda u=url: client.get(u, headers=eap_bearer("alice")), f"GET {url} as alice")
        assert own.status_code == 200, f"positive control {route.path}: alice got {own.status_code}"


# ---------------------------------------------------------------------------
# 4. What a handler actually sees
# ---------------------------------------------------------------------------

async def _echo_x_headers(request: Request) -> dict[str, str]:
    return {name: value for name, value in request.headers.items() if name.startswith("x-")}


def test_forged_identity_headers_are_stripped_before_handlers_see_them() -> None:
    added = not any(getattr(r, "path", None) == ECHO_PATH for r in app.routes)
    if added:
        app.add_api_route(ECHO_PATH, _echo_x_headers, methods=["GET"], include_in_schema=False)
    try:
        response = TestClient(app).get(
            ECHO_PATH,
            headers={
                "X-SPIFFE-ID": "spiffe://signalloom.demo/ns/eap-0a1b2c3d/sa/tenant-app",
                "X-Tenant-Id": "0a1b2c3d",
                "X-Forwarded-User": "alice",
                "X-Principal-Sub": "alice",
                "X-Other": "keep",
            },
        )
        assert response.status_code == 200
        assert response.json() == {"x-other": "keep"}
    finally:
        if added:
            app.router.routes[:] = [r for r in app.router.routes if getattr(r, "path", None) != ECHO_PATH]


# ---------------------------------------------------------------------------
# 5. Websocket
# ---------------------------------------------------------------------------

def test_forged_headers_do_not_reach_a_websocket_handler(two_tenants) -> None:
    alice = two_tenants["alice"]
    url = f"/api/v1/environments/{alice['id']}/telemetry"

    def as_bob_forged() -> int | str:
        client = EAPClient(app, subject="bob")
        try:
            with client.websocket_connect(url, headers=_forged_as(alice["hash"])) as ws:
                return f"accepted, first frame {ws.receive_text()!r}"
        except WebSocketDisconnect as disconnect:
            return disconnect.code

    outcome = _run_with_deadline(as_bob_forged, f"WS {url} as bob")
    assert outcome == 4404, f"bob with forged headers on alice's telemetry: {outcome}"

    def as_alice() -> list[dict[str, Any]]:
        client = EAPClient(app, subject="alice")
        frames: list[dict[str, Any]] = []
        with client.websocket_connect(url) as ws:
            while True:
                frame = ws.receive_json()
                frames.append(frame)
                if frame.get("event") == "stream_end":
                    return frames

    frames = _run_with_deadline(as_alice, f"WS {url} as alice")
    assert frames[-1]["event"] == "stream_end"
    assert all(frame["environment_id"] == alice["id"] for frame in frames)
    assert frames[-1]["count"] == len(frames) - 1 >= 1, "alice's own stream should carry her provisioning events"
