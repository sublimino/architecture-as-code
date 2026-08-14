"""Driving a privileged demo phase must leave a durable record.

``POST /api/demo/supercred/runs`` and ``POST /api/demo/supercred/reset`` are superadmin-gated
controls that mutate the cluster. Reset additionally preempts and cancels
whatever phase is running. Neither wrote anything durable: the run history lived
in a module-level dict that dies with the pod, while ``GET /api/demo/supercred/status``
described that dict as "the run history of a cluster-mutating control plane --
which privileged phase was driven, by whom, when, and whether it failed". That
is a description of an audit trail, kept in memory.

The record is written BEFORE the process is spawned. A row added on completion
is missing from exactly the cases worth investigating -- the pod killed
mid-run, the script wedged, the node lost. Ordering is the guarantee: audit
first, spawn second.

These tests drive the in-memory audit path, which is what the API serves with no
database configured, so they need no Postgres.
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
SUBJECT_TENANTS = {"demo-audit": "tenant-demo-audit"}
TENANT = "tenant-demo-audit"
SUPERADMIN_EMAIL = "instructor@signalloom.local"


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
            "sub": "demo-audit",
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


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(settings, "api_superadmin_emails", {SUPERADMIN_EMAIL})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    # demo_runner binds _get_pool at import, so both names have to move.
    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    monkeypatch.setattr(demo_runner, "_get_pool", _no_pool)

    # The run itself is not under test here -- only the record of it being
    # asked for. Stubbing the spawn keeps the test from driving a real script,
    # and proves the audit does not depend on the run succeeding.
    def _fake_spawn(step_id: str, kind: str) -> Any:
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


def _audit_events(client: TestClient) -> list[dict[str, Any]]:
    return client.get("/api/audit", headers=_bearer()).json()["events"]


def test_running_a_privileged_phase_is_recorded(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/runs", json={"step": "4"}, headers=_bearer())

    assert response.status_code == 202, response.text
    event = _audit_events(client)[0]
    assert event["event_type"] == "demo.phase_run"
    assert event["detail"]["step_id"] == "4"


def test_resetting_the_demo_is_recorded(client: TestClient) -> None:
    """The most destructive control in the product left no durable trace."""
    response = client.post("/api/demo/supercred/reset", headers=_bearer())

    assert response.status_code == 202, response.text
    event = _audit_events(client)[0]
    assert event["event_type"] == "demo.reset_requested"
    assert event["detail"]["preempts_active_run"] is True


def test_the_record_names_the_operator_not_a_literal(client: TestClient) -> None:
    """Who invoked it is the question this row exists to answer.

    The browser-side predecessor could not answer it at all, and the rest of
    the audit writers answer it with the constant "demo-actor". This one takes
    the identity from the validated token, which is the only source that is
    actually true.
    """
    client.post("/api/demo/supercred/reset", headers=_bearer())

    assert _audit_events(client)[0]["actor"] == SUPERADMIN_EMAIL


def test_the_record_does_not_claim_the_cluster_action_succeeded(
    client: TestClient,
) -> None:
    """The runner cannot see the relabel or the lease revocation.

    Those belong to the SuperCred proxy, which reports to nobody. A row naming
    an outcome would be the same fabrication the stun payload used to carry,
    relocated -- so the detail records the invocation and stops there.
    """
    client.post("/api/demo/supercred/runs", json={"step": "4"}, headers=_bearer())

    detail = _audit_events(client)[0]["detail"]
    assert "outcome" not in detail
    assert "to_state" not in detail
    assert detail["kind"] == "step"


def test_a_non_superadmin_is_refused_and_leaves_no_record(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A refused request changed nothing, so it must not look like it did."""
    monkeypatch.setattr(settings, "api_superadmin_emails", {"someone-else@signalloom.local"})

    response = client.post("/api/demo/supercred/reset", headers=_bearer())

    assert response.status_code == 403, response.text
    assert [e for e in _audit_events(client) if e["event_type"].startswith("demo.")] == []
