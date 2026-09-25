"""SLEA-P4-2 end-to-end acceptance suite for the kusari EAP environment lifecycle.

Drives the real FastAPI app in-process (TestClient) through
provision -> resolve -> status -> probe -> extend -> teardown -> verify clean,
and cross-checks the canonical kusari vector across the Python
engine, the REST API and scripts/eap/tailscale-eap-env.sh.

Tailscale is exercised ONLY in explicitly pinned mock mode
(TAILSCALE_MOCK=1, private TAILSCALE_MOCK_DIR under tmp_path). The script's
live mode runs `tailscale up --hostname=...` and `tailscale logout`, which on
a developer workstation renames and de-registers that machine's own node.
Nothing here asserts real-mesh reachability.

Each test gets a fresh registry, and the fixture's finalizer tears down
anything left active and fails if it cannot, so an assertion failing halfway
still leaves zero orphans.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import environment_routing
from environment_routing import (
    EAP_SECURITY_HEADERS,
    EnvironmentRegistry,
    EnvironmentState,
    build_environment_urls,
    derive_customer_hash,
)
from main import app
from conftest import EAPClient

# EAPR-P2-1: the environments/webhooks routers are mounted behind
# authenticated_principal; every request here carries a real tenant-a token
# (see tests/conftest.py).
EAP_AUTHENTICATED = True

COMPANY = "kusari"
HASH = derive_customer_hash(COMPANY)
HOSTNAME = f"sl-eap-{HASH}"
INTERNAL_URL = f"https://{HOSTNAME}.tailscale"
EXTERNAL_FQDN = f"https://{HOSTNAME}.ts.net"
OIDC_REDIRECT = f"{INTERNAL_URL}/auth/callback"
BASE = "/api/v1/environments"

REPO_ROOT = Path(__file__).resolve().parents[5]
TAILSCALE_SCRIPT = REPO_ROOT / "scripts" / "eap" / "tailscale-eap-env.sh"
DEFAULT_MOCK_DIR = Path("/tmp/tailscale-eap-mock")


# ── Fixtures ────────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def fresh_registry(monkeypatch):
    """Swap in an empty registry per test; tear down and assert zero orphans after."""
    registry = EnvironmentRegistry()
    monkeypatch.setattr(environment_routing, "GLOBAL_ENVIRONMENT_REGISTRY", registry)
    yield registry
    for rec in registry.list(limit=10_000):
        if rec.state != EnvironmentState.TERMINATED:
            registry.teardown(rec.id, reason="fixture cleanup")
    orphans = [r.id for r in registry.list(limit=10_000) if r.state != EnvironmentState.TERMINATED]
    assert orphans == [], f"orphaned environments left active: {orphans}"


@pytest.fixture
def client():
    # No context manager: the lifespan would open the PostgreSQL pool, which
    # the environment routing engine does not use.
    return EAPClient(app)


@pytest.fixture
def mock_dir(tmp_path):
    d = tmp_path / "tailscale-eap-mock"
    yield d
    assert not (d / HOSTNAME).exists(), "mock tailscale node state survived teardown"


class Trace:
    """Records every request/response pair of a lifecycle run as JSON."""

    def __init__(self, client: TestClient):
        self.client = client
        self.steps: List[Dict[str, Any]] = []

    def call(self, step: str, method: str, path: str, body: Optional[dict] = None):
        kwargs = {"json": body} if body is not None else {}
        resp = self.client.request(method, path, **kwargs)
        try:
            payload = resp.json()
        except ValueError:
            payload = resp.text
        self.steps.append(
            {
                "step": step,
                "request": {"method": method, "path": path, "body": body},
                "response": {"status": resp.status_code, "body": payload},
            }
        )
        return resp

    def dump(self, path: Path) -> None:
        path.write_text(json.dumps({"company_name": COMPANY, "steps": self.steps}, indent=2, default=str) + "\n")


def _provision(client: TestClient, ttl: int = 180, company: str = COMPANY):
    return client.post(f"{BASE}/provision", json={"company_name": company, "ttl_minutes": ttl})


def _teardown(client: TestClient, env_id: str, reason: str = "Acceptance test completed"):
    return client.post(f"{BASE}/{env_id}/teardown", json={"reason": reason})


def _parse(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _run_script(*args: str, mock_dir: Path) -> subprocess.CompletedProcess:
    env = {
        **os.environ,
        "TAILSCALE_MOCK": "1",
        "TAILSCALE_MOCK_DIR": str(mock_dir),
        "SIGNAL_LOOM_EAP_SALT": os.environ.get("SIGNAL_LOOM_EAP_SALT", "test-eap-salt-2026"),
        "LC_ALL": "C.UTF-8",
    }
    return subprocess.run(
        ["bash", str(TAILSCALE_SCRIPT), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def _drain_ws(client: TestClient, env_id: str) -> List[Dict[str, Any]]:
    frames = []
    with client.websocket_connect(f"{BASE}/{env_id}/telemetry") as ws:
        while True:
            frame = ws.receive_json()
            frames.append(frame)
            if frame["event"] == "stream_end":
                break
    return frames


# ── Full lifecycle ──────────────────────────────────────────────────────────


def test_kusari_full_lifecycle(client, mock_dir, tmp_path):
    """provision -> resolve -> status -> probe -> extend -> teardown -> idempotent teardown."""
    t = Trace(client)

    # Step 1: provision
    r = t.call("1-provision", "POST", f"{BASE}/provision", {"company_name": COMPANY, "ttl_minutes": 180})
    assert r.status_code == 201, r.text
    env = r.json()
    assert env["customer_hash"] == HASH
    assert env["internal_mesh_url"] == INTERNAL_URL
    assert env["external_fqdn"] == EXTERNAL_FQDN
    assert env["hostname"] == HOSTNAME
    env_id = env["id"]
    created, first_expiry = _parse(env["created_at"]), _parse(env["expires_at"])
    assert first_expiry - created == timedelta(minutes=180)

    # Step 2: resolve by name and by hash — identical URL sets, bound to this env
    by_name = t.call("2a-resolve-by-name", "POST", f"{BASE}/resolve-domain", {"company_name": COMPANY})
    by_hash = t.call("2b-resolve-by-hash", "POST", f"{BASE}/resolve-domain", {"customer_hash": HASH})
    assert by_name.status_code == by_hash.status_code == 200
    url_keys = ("customer_hash", "hostname", "internal_mesh_url", "external_fqdn", "oidc_redirect_uri")
    for body in (by_name.json(), by_hash.json()):
        assert {k: body[k] for k in url_keys} == {k: env[k] for k in url_keys}
        assert body["is_active"] is True
        assert body["environment_id"] == env_id

    # Step 3: status
    s = t.call("3-status", "GET", f"{BASE}/{env_id}")
    assert s.status_code == 200
    assert s.json()["state"] in (EnvironmentState.PROVISIONING.value, EnvironmentState.READY.value)

    # Step 3b: health probe
    p = t.call("3b-probe", "GET", f"{BASE}/{env_id}/probe")
    assert p.status_code == 200
    assert p.json()["reachable"] is True and p.json()["hostname"] == HOSTNAME

    # Mesh node (explicitly mocked — see module docstring)
    prov = _run_script("provision", COMPANY, mock_dir=mock_dir)
    assert prov.returncode == 0, prov.stderr
    node = json.loads((mock_dir / HOSTNAME / "state.json").read_text())
    assert node["customer_hash"] == HASH and node["mock"] is True

    # Step 4: extend by exactly 120 minutes (relative delta, not wall clock)
    e = t.call("4-extend", "POST", f"{BASE}/{env_id}/extend", {"additional_minutes": 120})
    assert e.status_code == 200
    assert _parse(e.json()["expires_at"]) - first_expiry == timedelta(minutes=120)

    # Step 5: teardown
    d = t.call("5-teardown", "POST", f"{BASE}/{env_id}/teardown", {"reason": "Acceptance test completed"})
    assert d.status_code == 200
    assert d.json()["state"] == EnvironmentState.TERMINATED.value
    down = _run_script("teardown", COMPANY, mock_dir=mock_dir)
    assert down.returncode == 0, down.stderr

    # Step 6: idempotent repeat
    d2 = t.call("6-teardown-repeat", "POST", f"{BASE}/{env_id}/teardown", {"reason": "Acceptance test completed"})
    assert d2.status_code == 200
    assert d2.json()["state"] == EnvironmentState.TERMINATED.value
    assert d2.json()["expires_at"] == d.json()["expires_at"]

    # Clean state
    gone = t.call("7-probe-after-teardown", "GET", f"{BASE}/{env_id}/probe")
    assert gone.status_code == 410
    after = t.call("8-resolve-after-teardown", "POST", f"{BASE}/resolve-domain", {"company_name": COMPANY})
    assert after.json()["is_active"] is False

    events = _drain_ws(client, env_id)
    t.steps.append({"step": "9-telemetry-stream", "events": events})
    assert [f["event"] for f in events] == [
        "provisioned",
        "ttl_extended",
        "teardown_requested",
        "terminated",
        "stream_end",
    ]

    out = Path(os.environ.get("EAP_LIFECYCLE_TRACE") or tmp_path / "kusari-lifecycle-trace.json")
    t.dump(out)
    assert json.loads(out.read_text())["steps"][0]["response"]["body"]["customer_hash"] == HASH


# ── Canonical vector ────────────────────────────────────────────────────────


def test_kusari_canonical_hash_strict(client, mock_dir):
    """Canonical hash must agree across engine, API, resolve (both keys) and the shell script."""
    assert derive_customer_hash(COMPANY) == HASH
    for variant in ("Kusari", "  KUSARI\t", "\nkusari "):
        assert derive_customer_hash(variant) == HASH
    assert build_environment_urls(HASH) == {
        "hostname": HOSTNAME,
        "internal_mesh_url": INTERNAL_URL,
        "external_fqdn": EXTERNAL_FQDN,
        "oidc_redirect_uri": OIDC_REDIRECT,
    }
    assert derive_customer_hash(COMPANY, salt="another-salt") != HASH

    r = _provision(client)
    assert r.status_code == 201
    assert r.json()["customer_hash"] == HASH
    for body in ({"company_name": COMPANY}, {"company_name": "KUSARI "}, {"customer_hash": HASH}, {"customer_hash": HASH.upper()}):
        res = client.post(f"{BASE}/resolve-domain", json=body)
        assert res.status_code == 200, body
        assert res.json()["customer_hash"] == HASH

    sh_hash = _run_script("hash", COMPANY, mock_dir=mock_dir)
    assert sh_hash.returncode == 0 and sh_hash.stdout.strip() == HASH
    sh_urls = json.loads(_run_script("urls", COMPANY, mock_dir=mock_dir).stdout)
    assert (sh_urls["customer_hash"], sh_urls["internal_mesh_url"], sh_urls["external_fqdn"]) == (
        HASH,
        INTERNAL_URL,
        EXTERNAL_FQDN,
    )


def test_kusari_extend_and_teardown(client):
    env = _provision(client).json()
    before = _parse(env["expires_at"])
    ext = client.post(f"{BASE}/{env['id']}/extend", json={"additional_minutes": 120})
    assert ext.status_code == 200
    assert _parse(ext.json()["expires_at"]) - before == timedelta(minutes=120)
    # And the status endpoint agrees with what extend returned
    assert client.get(f"{BASE}/{env['id']}").json()["expires_at"] == ext.json()["expires_at"]

    td = _teardown(client, env["id"])
    assert td.status_code == 200
    assert td.json()["state"] == "terminated"


def test_kusari_teardown_idempotency(client, fresh_registry):
    env = _provision(client).json()
    first = _teardown(client, env["id"])
    assert first.status_code == 200
    rec = fresh_registry.get(env["id"])
    version, events = rec.version, len(rec.events)
    for _ in range(3):
        again = _teardown(client, env["id"], reason="repeat")
        assert again.status_code == 200
        assert again.json()["state"] == "terminated"
    # A no-op teardown must not bump version, rewrite the reason, or log events.
    assert (rec.version, len(rec.events), rec.teardown_reason) == (version, events, "Acceptance test completed")
    # Empty-body teardown is also accepted on an already-terminated env
    assert client.post(f"{BASE}/{env['id']}/teardown").status_code == 200
    # Clean reset: the same customer can be provisioned again with the same hash
    again = _provision(client)
    assert again.status_code == 201
    assert again.json()["customer_hash"] == HASH and again.json()["id"] != env["id"]


# ── Routing surfaces ────────────────────────────────────────────────────────


def test_kusari_oidc_redirect_url(client):
    env = _provision(client).json()
    assert env["oidc_redirect_uri"] == OIDC_REDIRECT
    res = client.post(f"{BASE}/resolve-domain", json={"customer_hash": HASH}).json()
    assert res["oidc_redirect_uri"] == OIDC_REDIRECT
    assert client.get(f"{BASE}/{env['id']}").json()["oidc_redirect_uri"] == OIDC_REDIRECT


def test_kusari_ttl_expiry_warning(client, fresh_registry):
    """Warning fires strictly below 30 minutes remaining; set expiry directly, never sleep."""
    env = _provision(client, ttl=180).json()
    assert env["expiry_warning"] is False
    rec = fresh_registry.get(env["id"])
    now = datetime.now(timezone.utc)
    rec.expires_at = now + timedelta(minutes=31)
    assert client.get(f"{BASE}/{env['id']}").json()["expiry_warning"] is False
    rec.expires_at = now + timedelta(minutes=29)
    assert client.get(f"{BASE}/{env['id']}").json()["expiry_warning"] is True
    assert client.get(f"{BASE}/{env['id']}/probe").json()["expiry_warning"] is True
    # A terminated environment never warns
    _teardown(client, env["id"])
    assert client.get(f"{BASE}/{env['id']}").json()["expiry_warning"] is False


def test_kusari_post_teardown_cleanup(client, mock_dir):
    default_mock_existed = (DEFAULT_MOCK_DIR / HOSTNAME).exists()
    env = _provision(client).json()
    assert _run_script("provision", COMPANY, mock_dir=mock_dir).returncode == 0
    assert _run_script("serve", COMPANY, mock_dir=mock_dir).returncode == 0
    assert (mock_dir / HOSTNAME / "serve.json").exists()

    assert _teardown(client, env["id"]).status_code == 200
    down = _run_script("teardown", COMPANY, mock_dir=mock_dir)
    assert down.returncode == 0, down.stderr

    # Operational requests after teardown are refused as Gone
    assert client.get(f"{BASE}/{env['id']}/probe").status_code == 410
    ext = client.post(f"{BASE}/{env['id']}/extend", json={"additional_minutes": 10})
    assert ext.status_code == 410
    # api_compat's handler replaces every HTTPException detail with this envelope.
    assert ext.json() == {"error": {"code": "request_error", "message": "Request failed"}}
    # Routing no longer considers it active, and nothing is listed as live
    assert client.post(f"{BASE}/resolve-domain", json={"company_name": COMPANY}).json()["is_active"] is False
    assert client.get(f"{BASE}/", params={"state": "ready"}).json() == []
    # Mesh node state (mock) is gone and nothing leaked into the shared /tmp default
    assert not (mock_dir / HOSTNAME).exists()
    assert (DEFAULT_MOCK_DIR / HOSTNAME).exists() == default_mock_existed


def test_kusari_websocket_telemetry_streaming(client):
    env = _provision(client).json()
    client.post(f"{BASE}/{env['id']}/extend", json={"additional_minutes": 30})
    frames = _drain_ws(client, env["id"])
    assert [f["event"] for f in frames] == ["provisioned", "ttl_extended", "stream_end"]
    assert all(f["environment_id"] == env["id"] for f in frames)
    assert [f["seq"] for f in frames[:-1]] == [1, 2]
    assert frames[1]["detail"]["additional_minutes"] == 30
    assert frames[-1]["count"] == 2
    # Unknown environments are refused before accept
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect(f"{BASE}/does-not-exist/telemetry") as ws:
            ws.receive_json()
    assert exc.value.code == 4404


def _header_cases(client: TestClient) -> Dict[str, Any]:
    env = _provision(client).json()
    eid = env["id"]
    cases = {
        "provision-201": _provision(client, company="header-corp"),
        "provision-200": _provision(client),
        "provision-422": client.post(f"{BASE}/provision", json={"company_name": "x"}),
        "resolve-200": client.post(f"{BASE}/resolve-domain", json={"company_name": COMPANY}),
        "resolve-400": client.post(f"{BASE}/resolve-domain", json={}),
        "list-200": client.get(f"{BASE}/"),
        "get-200": client.get(f"{BASE}/{eid}"),
        "get-404": client.get(f"{BASE}/nope"),
        "probe-200": client.get(f"{BASE}/{eid}/probe"),
        "extend-200": client.post(f"{BASE}/{eid}/extend", json={"additional_minutes": 5}),
        "teardown-200": _teardown(client, eid),
    }
    cases["probe-410"] = client.get(f"{BASE}/{eid}/probe")
    cases["extend-410"] = client.post(f"{BASE}/{eid}/extend", json={"additional_minutes": 5})
    return cases


def test_security_response_headers(client, tmp_path):
    cases = _header_cases(client)
    report = {}
    for name, resp in cases.items():
        expected_status = int(name.rsplit("-", 1)[1])
        assert resp.status_code == expected_status, (name, resp.text)
        present = {h: resp.headers.get(h) for h in EAP_SECURITY_HEADERS}
        report[name] = {"status": resp.status_code, "headers": present}
        assert present == EAP_SECURITY_HEADERS, name
    assert "frame-ancestors 'none'" in EAP_SECURITY_HEADERS["Content-Security-Policy"]
    assert EAP_SECURITY_HEADERS["X-Frame-Options"] == "DENY"
    out = os.environ.get("EAP_HEADER_REPORT")
    Path(out or tmp_path / "headers.json").write_text(json.dumps(report, indent=2) + "\n")
    # Scope check: the strict CSP is not applied app-wide (it would break /docs)
    assert "Content-Security-Policy" not in client.get("/health").headers


# ── Synthetic users, concurrency, chaos ─────────────────────────────────────


def test_kusari_synthetic_http_client(client):
    """Virtual users repeatedly resolve, read status and probe a live environment."""
    env = _provision(client).json()
    docs = client.get("/docs")
    # /docs is the only HTML fe-signalloom serves; the dashboard is a separate app.
    assert docs.status_code == 200
    assert "<title>Signal Loom Discovery Portal" in docs.text

    latencies: List[float] = []
    lock = threading.Lock()

    def user(n: int) -> List[int]:
        codes = []
        for _ in range(10):
            for method, path, body in (
                ("POST", f"{BASE}/resolve-domain", {"company_name": COMPANY}),
                ("GET", f"{BASE}/{env['id']}", None),
                ("GET", f"{BASE}/{env['id']}/probe", None),
            ):
                start = time.perf_counter()
                r = client.request(method, path, **({"json": body} if body else {}))
                with lock:
                    latencies.append(time.perf_counter() - start)
                codes.append(r.status_code)
        return codes

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(user, range(8)))
    flat = [c for codes in results for c in codes]
    assert len(flat) == 8 * 10 * 3
    assert set(flat) == {200}
    latencies.sort()
    assert latencies[int(len(latencies) * 0.95)] < 1.0


def test_kusari_concurrent_provision_race(client):
    """Racing provisions for one customer yield exactly one 201; distinct customers stay isolated."""

    def attempt(company: str) -> tuple[str, int, Optional[str]]:
        r = _provision(client, company=company)
        return company, r.status_code, r.json().get("customer_hash")

    companies = [COMPANY] * 6 + [f"tenant-{i}" for i in range(6)]
    with ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(attempt, companies))
    kusari = [code for c, code, _ in results if c == COMPANY]
    assert sorted(kusari) == [200] * 5 + [201]
    others = {c: h for c, code, h in results if c != COMPANY and code == 201}
    assert len(others) == 6 and HASH not in others.values()
    assert len(set(others.values())) == 6


def test_kusari_graceful_error_during_teardown(client, fresh_registry):
    """A request that lands mid-teardown gets a structured 503, not a 5xx crash."""
    env = _provision(client).json()
    rec = fresh_registry.get(env["id"])
    rec.state = EnvironmentState.TEARING_DOWN
    r = client.get(f"{BASE}/{env['id']}/probe")
    assert r.status_code == 503
    assert r.json() == {"error": {"code": "request_error", "message": "Request failed"}}
    assert r.headers["content-type"].startswith("application/json")
    rec.state = EnvironmentState.READY  # let the fixture finish the teardown


def test_kusari_chaos_pod_restart_recovery(client, monkeypatch):
    """Simulate the backend pod dying mid-session: the in-memory registry is lost.

    Routing must recover deterministically (same URLs), the lost env reads 404,
    and the customer can be re-provisioned onto the same hash.
    """
    env = _provision(client).json()
    stop = threading.Event()
    seen: List[int] = []

    def hammer():
        while not stop.is_set():
            seen.append(client.get(f"{BASE}/{env['id']}/probe").status_code)

    worker = threading.Thread(target=hammer)
    worker.start()
    time.sleep(0.05)
    monkeypatch.setattr(environment_routing, "GLOBAL_ENVIRONMENT_REGISTRY", EnvironmentRegistry())
    time.sleep(0.05)
    stop.set()
    worker.join(timeout=5)
    assert seen and set(seen) <= {200, 404}, set(seen)
    assert not any(code >= 500 for code in seen)

    assert client.get(f"{BASE}/{env['id']}").status_code == 404
    res = client.post(f"{BASE}/resolve-domain", json={"company_name": COMPANY}).json()
    assert (res["internal_mesh_url"], res["is_active"]) == (INTERNAL_URL, False)
    again = _provision(client)
    assert again.status_code == 201 and again.json()["customer_hash"] == HASH
    environment_routing.GLOBAL_ENVIRONMENT_REGISTRY.teardown(again.json()["id"], reason="chaos cleanup")
