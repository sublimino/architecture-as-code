"""A pool-less runner must not audit into a dict that dies with the pod.

``test_demo_runner_audit.py`` proves the privileged-invocation record is written
before the spawn, and it passes. It passes because it mounts ``main:app``, where
``demo_runner``'s router and ``api_compat``'s in-memory store are co-resident in
one process -- so ``_record_memory_audit`` lands in the very store that
``GET /api/audit`` reads back. The deployed topology is not that. The runner is
its own workload (``demo_runner_main.py``, which mounts the runner router and
deliberately nothing else, so that it "must not initialise the PostgreSQL
pool"), and its Deployment carries no database configuration of any kind. In
production ``_get_pool()`` therefore returns ``None`` on every call, every
privileged phase run and every reset goes to a module-level dict, and the pod
that holds it is the same pod the demo restarts.

That is precisely the defect the server-side audit was built to remove -- the
run history living in a per-process dict that dies with the pod -- reintroduced
one layer down, and invisible to the test suite because the test topology
supplies the store the deployment lacks.

The fix is not a database connection for the runner. The runner is the one
workload that executes privileged scripts against the cluster, and its
NetworkPolicy is deliberately tight enough to explain in comments what is *not*
in it and why; port 5432 appears nowhere. Widening that to broaden an audit
trail trades the wrong thing. The runner instead forwards the record to
fe-signalloom over HTTP, authenticated with the operator's own bearer token --
the same token the runner has already validated, bound to the same issuer and
audience fe-signalloom validates against.

These tests assert the deployed shape: no local pool, a configured sink, and no
silent fallback in between.
"""
from __future__ import annotations

import socket
import time
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import demo_runner
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# Own tenant: the in-memory stores are module-level and outlive a single test.
SUBJECT_TENANTS = {"demo-forward": "tenant-demo-forward"}
TENANT = "tenant-demo-forward"
SUPERADMIN_EMAIL = "instructor-forward@signalloom.local"
SINK_URL = "http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000"


def _bearer() -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": "demo-forward",
            "email": SUPERADMIN_EMAIL,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


class _ReadyPool:
    async def close(self) -> None:
        pass


class _RecordedPost:
    """What the runner sent, captured instead of dispatched.

    The runner's own NetworkPolicy is the reason this is a stub rather than a
    live call: these tests must run with no cluster, and ``socket.connect`` is
    poisoned below so that a regression which bypasses the sink and dials out
    directly fails loudly rather than hanging.
    """

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.fail_with: Exception | None = None

    async def __call__(self, url: str, *, json: dict[str, Any], headers: dict[str, str]) -> None:
        if self.fail_with is not None:
            raise self.fail_with
        self.calls.append({"url": url, "json": json, "headers": headers})


@pytest.fixture
def sink() -> _RecordedPost:
    return _RecordedPost()


@pytest.fixture
def spawns() -> list[tuple[str, str]]:
    return []


@pytest.fixture
def client(
    monkeypatch: pytest.MonkeyPatch, sink: _RecordedPost, spawns: list[tuple[str, str]],
) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(settings, "api_superadmin_emails", {SUPERADMIN_EMAIL})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    # The deployed runner's condition, asserted rather than assumed: no pool.
    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    monkeypatch.setattr(demo_runner, "_get_pool", _no_pool)

    monkeypatch.setenv(demo_runner._ENV_AUDIT_SINK, SINK_URL)
    monkeypatch.setattr(demo_runner, "_post_audit_sink", sink)

    def _fake_spawn(step_id: str, kind: str) -> Any:
        spawns.append((step_id, kind))
        return demo_runner._Run(
            run_id="run-test", step_id=step_id, kind=kind, status="running",
            started_at=demo_runner.datetime.now(demo_runner.UTC), finished_at=None,
            exit_code=None, error=None, _process=None, _log=bytearray(),
            _log_truncated=False, _timed_out=False,
            _lock=demo_runner.threading.Lock(),
            _log_changed=demo_runner.threading.Condition(demo_runner.threading.Lock()),
            _done=demo_runner.threading.Event(),
        )

    monkeypatch.setattr(demo_runner, "_spawn_run", _fake_spawn)
    monkeypatch.setattr(demo_runner, "_cancel_active", lambda: None)

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    api_compat.reset_tenant_state(TENANT)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state(TENANT)


def test_a_runner_without_a_database_forwards_the_record_instead_of_dropping_it(
    client: TestClient, sink: _RecordedPost,
) -> None:
    """The deployed runner has no pool, so the in-memory branch was every run."""
    response = client.post("/api/demo/supercred/runs", json={"step": "4"}, headers=_bearer())

    assert response.status_code == 202, response.text
    assert len(sink.calls) == 1, "a pool-less runner recorded nothing durable"
    assert sink.calls[0]["url"].startswith(SINK_URL)


def test_the_forwarded_record_carries_no_client_authored_narrative(
    client: TestClient, sink: _RecordedPost,
) -> None:
    """The sink derives the event; the runner reports only what it was asked for.

    An actor, an event_type or an outcome travelling in this body would put the
    audit row's most load-bearing fields on the wire, where the next caller can
    author them. The identity is re-derived at the sink from the same token.
    """
    client.post("/api/demo/supercred/runs", json={"step": "4"}, headers=_bearer())

    assert sink.calls[0]["json"] == {"step_id": "4", "kind": "step"}


def test_the_operators_own_token_authenticates_the_forward(
    client: TestClient, sink: _RecordedPost,
) -> None:
    """No new credential: the runner presents the token it already validated."""
    headers = _bearer()

    client.post("/api/demo/supercred/reset", headers=headers)

    assert sink.calls[0]["headers"]["Authorization"] == headers["Authorization"]


def test_a_failed_forward_prevents_the_spawn(
    client: TestClient, sink: _RecordedPost, spawns: list[tuple[str, str]],
) -> None:
    """Fail-closed, preserving the property the ordering was chosen for.

    The record is written before the spawn so that a spawn cannot happen
    without one. A forward that fails and is swallowed would keep the ordering
    and lose the guarantee -- the run would proceed unrecorded, which is the
    state this whole mechanism exists to make impossible.
    """
    sink.fail_with = RuntimeError("sink unreachable")

    response = client.post("/api/demo/supercred/runs", json={"step": "4"}, headers=_bearer())

    assert response.status_code == 503, response.text
    assert response.json()["error"]["code"] == "audit_unavailable"
    assert spawns == [], "a privileged phase ran with no durable record of who asked"


def test_a_failed_forward_prevents_the_reset(
    client: TestClient, sink: _RecordedPost, spawns: list[tuple[str, str]],
) -> None:
    """Reset is the most destructive control, so it fails closed too."""
    sink.fail_with = RuntimeError("sink unreachable")

    response = client.post("/api/demo/supercred/reset", headers=_bearer())

    assert response.status_code == 503, response.text
    assert spawns == []


def test_a_refused_caller_is_never_forwarded(
    client: TestClient, sink: _RecordedPost, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A 403 changed nothing and must not put a row anywhere."""
    monkeypatch.setattr(settings, "api_superadmin_emails", {"someone-else@signalloom.local"})

    response = client.post("/api/demo/supercred/reset", headers=_bearer())

    assert response.status_code == 403, response.text
    assert sink.calls == []
