"""Live connectors persist in Postgres, tenant-scoped, with credentials sealed.

The defect: with a database, connectors, their credentials and their scan
results lived only in module dicts, so a pod restart forgot every connector a
tenant had configured ("Anthropic Claude: Not configured" after a deploy), and
every live tenant was handed five "connected" demo connectors it never made.

These tests run with ``FakeConnectorPool`` (``tests/connector_store_fake.py``),
which keeps the ``tenant_connectors`` rows across a simulated restart: every
in-process dict is dropped, the pool is kept, and what the API reads back must
come from the pool. ``test_connector_store_postgres.py`` repeats the core flows
against a real PostgreSQL when ``DATABASE_URL`` is set.
"""
from __future__ import annotations

import logging
import secrets
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

import api_compat
import connector_credentials
from api_compat import settings
from db.connection import set_pool_for_testing
from routers.connectors import reset_connectors_for_testing
from tests.connector_store_fake import FakeConnectorPool
from tests.remote_agent_store_fake import FakeRemoteAgentPool
from tests.test_connectors_live_honesty import ANTHROPIC, _JWKClient, _mock_good_claude, _token

SECRET = "sk-ant-alice-SECRET-never-on-the-wire"
KEY_ENV = connector_credentials.KEY_FILE_ENV


def _key_file(tmp_path: Path, name: str = "connector-key") -> Path:
    path = tmp_path / name
    path.write_text(secrets.token_hex(32) + "\n")
    return path


@contextmanager
def _client(monkeypatch: pytest.MonkeyPatch, pool: Any, key_file: Path | None):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a", "bob": "tenant-b", "root": "tenant-a"})
    monkeypatch.setattr(settings, "api_superadmin_subjects", ["root"])
    monkeypatch.setattr(settings, "api_superadmin_emails", [])
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWKClient())
    if key_file is None:
        monkeypatch.delenv(KEY_ENV, raising=False)
    else:
        monkeypatch.setenv(KEY_ENV, str(key_file))

    async def _pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _pool)
    _forget_process_state()
    set_pool_for_testing(FakeRemoteAgentPool())
    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            yield client
    finally:
        set_pool_for_testing(None)
        _forget_process_state()


def _forget_process_state() -> None:
    """Everything a process restart loses."""
    for tenant in ("tenant-a", "tenant-b"):
        api_compat.reset_tenant_state(tenant)
    reset_connectors_for_testing()


def _create(client: TestClient, who: str, provider: str, credentials: dict[str, str] | None = None) -> str:
    resp = client.post("/api/v1/connectors", headers=_token(who),
                       json={"provider_id": provider, "credentials": credentials or {}})
    assert resp.status_code == 200, resp.text
    return resp.json()["connector_id"]


def _listed(client: TestClient, who: str) -> list[dict[str, Any]]:
    resp = client.get("/api/v1/connectors", headers=_token(who))
    assert resp.status_code == 200, resp.text
    return resp.json()["connectors"]


# ---------------------------------------------------------------------------
# No seeds in live mode.
# ---------------------------------------------------------------------------

def test_a_fresh_live_tenant_lists_zero_connectors(monkeypatch, tmp_path):
    with _client(monkeypatch, FakeRemoteAgentPool(), _key_file(tmp_path)) as client:
        assert _listed(client, "alice") == []
        status = client.get("/api/v1/connectors/status", headers=_token("alice")).json()
        assert (status["total_connectors"], status["active_connectors"], status["connectors"]) == (0, 0, [])


def test_a_fresh_live_tenant_cannot_toggle_or_scan_a_demo_connector(monkeypatch, tmp_path):
    with _client(monkeypatch, FakeRemoteAgentPool(), _key_file(tmp_path)) as client:
        for path in ("/api/v1/connectors/conn-aws-01/toggle", "/api/v1/connectors/conn-github-01/scan"):
            assert client.post(path, headers=_token("alice")).status_code == 404


# ---------------------------------------------------------------------------
# A restart forgets nothing the tenant configured.
# ---------------------------------------------------------------------------

def test_a_configured_connector_survives_a_restart_with_its_key_and_last_scan(monkeypatch, tmp_path):
    pool, key = FakeRemoteAgentPool(), _key_file(tmp_path)
    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [{"id": "a1", "name": "One"}]}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        probe = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": [{"id": "m1"}]}))
        with _client(monkeypatch, pool, key) as client:
            conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
            scan = client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()
            assert scan["status"] == "success"

        # Restart: every in-process dict is gone; only the pool remains.
        with _client(monkeypatch, pool, key) as client:
            (row,) = _listed(client, "alice")
            assert (row["connector_id"], row["provider_id"], row["status"]) == (conn_id, "claude", "connected")
            assert row["last_scan_at"] == scan["synced_at"]
            assert row["last_scan_status"] == "success"

            logs = client.get("/api/v1/connectors/claude/logs", headers=_token("alice"))
            assert logs.status_code == 200, logs.text
            assert logs.json()["records_scanned"] == scan["records_scanned"]

            calls_before = len(probe.calls)
            test = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()
            assert test["valid"] is True
            sent = [c.request.headers.get("x-api-key") for c in probe.calls[calls_before:]]
            assert sent == [SECRET]
            assert _listed(client, "alice")[0]["last_tested_at"] is not None


def test_a_disabled_connector_stays_disabled_across_a_restart(monkeypatch, tmp_path):
    pool, key = FakeRemoteAgentPool(), _key_file(tmp_path)
    with _client(monkeypatch, pool, key) as client:
        conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
        resp = client.post(f"/api/v1/connectors/{conn_id}/toggle", headers=_token("alice"), json={"enabled": False})
        assert resp.json()["status"] == "disconnected"
    with _client(monkeypatch, pool, key) as client:
        assert [c["status"] for c in _listed(client, "alice")] == ["disconnected"]


def test_disconnect_deletes_the_stored_credentials_and_scan_result(monkeypatch, tmp_path):
    pool = FakeRemoteAgentPool()
    with respx.mock(assert_all_called=False) as mock, _client(monkeypatch, pool, _key_file(tmp_path)) as client:
        _mock_good_claude(mock)
        conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert pool.row("tenant-a", conn_id)["credentials_ciphertext"]
        assert pool.row("tenant-a", conn_id)["last_scan_result"]
        assert client.delete(f"/api/v1/connectors/{conn_id}", headers=_token("alice")).status_code == 200
        row = pool.row("tenant-a", conn_id)
        assert (row["status"], row["credentials_ciphertext"], row["last_scan_result"]) == ("disconnected", None, None)


# ---------------------------------------------------------------------------
# Tenant isolation.
# ---------------------------------------------------------------------------

def test_one_tenants_connector_is_invisible_and_untouchable_to_another(monkeypatch, tmp_path):
    pool = FakeRemoteAgentPool()
    with respx.mock(assert_all_called=False) as mock, _client(monkeypatch, pool, _key_file(tmp_path)) as client:
        upstream = mock.route(host="api.anthropic.com").mock(return_value=httpx.Response(200, json={"data": []}))
        conn_id = _create(client, "alice", "claude", {"api_key": SECRET})

        assert _listed(client, "bob") == []
        bob = _token("bob")
        assert client.post(f"/api/v1/connectors/{conn_id}/toggle", headers=bob, json={"enabled": False}).status_code == 404
        assert client.post(f"/api/v1/connectors/{conn_id}/test", headers=bob).status_code == 404
        assert client.post("/api/v1/connectors/claude/scan", headers=bob).status_code == 404
        assert client.get("/api/v1/connectors/claude/logs", headers=bob).status_code == 404
        assert client.delete(f"/api/v1/connectors/{conn_id}", headers=bob).status_code == 404
        assert not upstream.called

        # Bob configuring the same provider gets his own row; alice's is untouched.
        _create(client, "bob", "claude", {"api_key": "sk-ant-bob"})
        assert pool.row("tenant-a", conn_id)["status"] == "connected"
        assert len(_listed(client, "alice")) == 1 and len(_listed(client, "bob")) == 1


# ---------------------------------------------------------------------------
# Credentials are sealed at rest and never leave the server.
# ---------------------------------------------------------------------------

def test_credentials_are_stored_only_as_tenant_bound_aes_gcm_ciphertext(monkeypatch, tmp_path):
    pool, key = FakeRemoteAgentPool(), _key_file(tmp_path)
    with _client(monkeypatch, pool, key) as client:
        conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
        stored = pool.row("tenant-a", conn_id)["credentials_ciphertext"]
        assert stored.startswith("vault:v1:")
        assert SECRET not in repr(pool.connectors)
        assert SECRET not in repr(pool.executed)
        assert connector_credentials.open_credentials("tenant-a", conn_id, stored) == {"api_key": SECRET}
        with pytest.raises(connector_credentials.CredentialDecryptError):
            connector_credentials.open_credentials("tenant-b", conn_id, stored)


def test_credentials_never_appear_in_any_response_or_log(monkeypatch, tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    with respx.mock(assert_all_called=False) as mock, \
            _client(monkeypatch, FakeRemoteAgentPool(), _key_file(tmp_path)) as client:
        _mock_good_claude(mock)
        headers = _token("root")
        bodies = [client.post("/api/v1/connectors", headers=headers,
                              json={"provider_id": "claude", "credentials": {"api_key": SECRET}}).text]
        conn_id = _listed(client, "root")[0]["connector_id"]
        for call in (
            lambda: client.get("/api/v1/connectors", headers=headers),
            lambda: client.get("/api/v1/connectors/status", headers=headers),
            lambda: client.post(f"/api/v1/connectors/{conn_id}/test", headers=headers),
            lambda: client.post("/api/v1/connectors/claude/scan", headers=headers),
            lambda: client.get("/api/v1/connectors/claude/logs", headers=headers),
            lambda: client.post(f"/api/v1/connectors/{conn_id}/toggle", headers=headers, json={"enabled": False}),
        ):
            bodies.append(call().text)
        assert all(SECRET not in b for b in bodies)
        assert SECRET not in caplog.text


def test_without_a_key_a_live_credential_write_is_503_and_stores_nothing(monkeypatch):
    pool = FakeRemoteAgentPool()
    with _client(monkeypatch, pool, None) as client:
        resp = client.post("/api/v1/connectors", headers=_token("alice"),
                           json={"provider_id": "claude", "credentials": {"api_key": SECRET}})
        assert resp.status_code == 503
        assert resp.json()["error"]["code"] == "credential_store_unavailable"
        assert pool.connectors == {}
        assert SECRET not in repr(pool.executed)


def test_a_malformed_key_file_is_503_not_a_fallback(monkeypatch, tmp_path):
    bad = tmp_path / "short"
    bad.write_text("deadbeef\n")
    pool = FakeRemoteAgentPool()
    with _client(monkeypatch, pool, bad) as client:
        resp = client.post("/api/v1/connectors", headers=_token("alice"),
                           json={"provider_id": "claude", "credentials": {"api_key": SECRET}})
        assert resp.status_code == 503
        assert resp.json()["error"]["code"] == "credential_store_unavailable"
        assert pool.connectors == {}


def test_without_a_key_a_connector_with_no_credentials_still_saves(monkeypatch):
    with _client(monkeypatch, FakeRemoteAgentPool(), None) as client:
        _create(client, "alice", "claude")
        assert [c["provider_id"] for c in _listed(client, "alice")] == ["claude"]


def test_a_key_that_disappears_after_saving_makes_the_stored_test_503(monkeypatch, tmp_path):
    pool, key = FakeRemoteAgentPool(), _key_file(tmp_path)
    with _client(monkeypatch, pool, key) as client:
        conn_id = _create(client, "alice", "claude", {"api_key": SECRET})
    with respx.mock(assert_all_called=False) as mock, _client(monkeypatch, pool, None) as client:
        upstream = mock.route(host="api.anthropic.com").mock(return_value=httpx.Response(200, json={"data": []}))
        resp = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice"))
        assert resp.status_code == 503
        assert resp.json()["error"]["code"] == "credential_store_unavailable"
        assert not upstream.called
