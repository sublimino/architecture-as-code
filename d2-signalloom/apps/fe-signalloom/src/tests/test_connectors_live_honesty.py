"""Live means live: with a database pool the connectors API reports only what it observed.

Fixture mode (``_get_pool()`` returns None) may serve demo results. These tests
run with a pool, so every success, count, duration, endpoint trace and verdict
the API returns has to come from a request it really made with the calling
tenant's own credentials -- never from a server env var, never invented.
Upstream HTTP is stubbed with respx; nothing leaves the process.
"""
from __future__ import annotations

import secrets
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import jwt
import pytest
import respx
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import connector_secret_store
from tests.connector_secret_store_fake import FakeKvStore
from api_compat import ComplianceSummaryInline, settings
from db.connection import set_pool_for_testing
from routers.connectors import SyncResult, reset_connectors_for_testing
from tests.connector_store_fake import FakeConnectorPool
from tests.remote_agent_store_fake import FakeRemoteAgentPool

ANTHROPIC = "https://api.anthropic.com"
OPENAI = "https://api.openai.com"
OPERATOR_KEY = "sk-ant-OPERATOR-must-never-be-used"

SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _JWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        return SimpleNamespace(key=SIGNING_KEY.public_key())


def _token(subject: str) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex", "aud": "signalloom-api", "azp": "signalloom-dashboard",
            "iat": now, "nbf": now, "exp": now + 300, "sub": subject,
        },
        SIGNING_KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}




# Keeps tenant_connectors rows like the real table; records every other statement.
_LivePool = FakeRemoteAgentPool


@contextmanager
def _client(monkeypatch: pytest.MonkeyPatch, *, live: bool = True):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a", "bob": "tenant-b", "root": "tenant-a"})
    monkeypatch.setattr(settings, "api_superadmin_subjects", ["root"])
    monkeypatch.setattr(settings, "api_superadmin_emails", [])
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWKClient())
    monkeypatch.setenv("ANTHROPIC_API_KEY", OPERATOR_KEY)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-admin-OPERATOR")
    # Connector credentials live in OpenBao KV v2 (SA-TODO-003): the fake store.
    connector_secret_store.set_store_for_testing(FakeKvStore())

    pool = _LivePool() if live else None

    async def _pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _pool)
    monkeypatch.setattr(settings, "database_url", "")  # fixture mode means no DSN, not an unreachable one
    for tenant in ("tenant-a", "tenant-b"):
        api_compat.reset_tenant_state(tenant)
    reset_connectors_for_testing()
    set_pool_for_testing(_LivePool())
    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            client.pool = pool  # type: ignore[attr-defined]
            yield client
    finally:
        set_pool_for_testing(None)
        for tenant in ("tenant-a", "tenant-b"):
            api_compat.reset_tenant_state(tenant)
        reset_connectors_for_testing()
        connector_secret_store.set_store_for_testing(None)


def _create(client: TestClient, headers: dict[str, str], provider: str, credentials: dict[str, str] | None = None) -> str:
    resp = client.post("/api/v1/connectors", headers=headers, json={"provider_id": provider, "credentials": credentials or {}})
    assert resp.status_code == 200, resp.text
    return resp.json()["connector_id"]


def _error_code(resp: httpx.Response) -> str:
    return resp.json()["error"]["code"]


def _sent_keys(route: respx.Route) -> list[str]:
    return [c.request.headers.get("x-api-key") or c.request.headers.get("authorization", "") for c in route.calls]


# ---------------------------------------------------------------------------
# 1. No operator-key fallback; unconfigured providers cannot be scanned.
# ---------------------------------------------------------------------------

def test_scan_of_a_provider_the_tenant_never_configured_is_404_and_sends_nothing(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        upstream = mock.route(host="api.anthropic.com").mock(return_value=httpx.Response(200, json={"data": []}))
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("bob"))
        assert resp.status_code == 404
        assert _error_code(resp) == "connector_not_configured"
        assert not upstream.called


def test_scan_without_a_stored_key_never_falls_back_to_the_server_key(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        upstream = mock.route(host="api.anthropic.com").mock(return_value=httpx.Response(200, json={"data": []}))
        _create(client, _token("bob"), "claude")
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("bob"))
        assert resp.status_code == 200, resp.text
        assert OPERATOR_KEY not in _sent_keys(upstream)
        assert not upstream.called
        body = resp.json()
        assert body["status"] == "error"
        assert body["records_scanned"]["agents"] is None


def test_stored_test_without_a_key_never_falls_back_to_the_server_key(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        upstream = mock.route(host="api.anthropic.com").mock(return_value=httpx.Response(200, json={"data": []}))
        conn_id = _create(client, _token("bob"), "claude")
        resp = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("bob"))
        assert resp.status_code == 200, resp.text
        assert not upstream.called
        assert resp.json()["valid"] is False


# ---------------------------------------------------------------------------
# 2. Discovery never renames agents by pattern.
# ---------------------------------------------------------------------------

def test_discovered_agent_name_updates_only_the_record_with_that_external_id():
    tenant = "tenant-rename"
    api_compat.reset_tenant_state(tenant)
    with api_compat._STORE_LOCK:
        api_compat._AGENTS[tenant] = {
            "claude-a": {"id": "claude-a", "name": "Keep A", "display_name": "Keep A", "model_name": "claude-x"},
            "claude-b": {"id": "claude-b", "name": "Old B", "display_name": "Old B", "model_name": "claude-x",
                         "external_agent_id": "agent_live_42"},
        }
    try:
        api_compat.update_claude_agent_name(tenant, "Live Name", "agent_live_42")
        with api_compat._STORE_LOCK:
            agents = api_compat._AGENTS[tenant]
            assert (agents["claude-a"]["name"], agents["claude-a"]["display_name"]) == ("Keep A", "Keep A")
            assert (agents["claude-b"]["name"], agents["claude-b"]["display_name"]) == ("Live Name", "Live Name")
    finally:
        api_compat.reset_tenant_state(tenant)


def test_live_scan_never_writes_agent_registry_by_pattern(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [{"id": "agent_x", "name": "X"}]}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert resp.status_code == 200, resp.text
        registry_writes = [sql for sql, _ in client.pool.executed if "agent_registry" in sql]
        assert registry_writes == []


# ---------------------------------------------------------------------------
# 3. A scan is audited before the upstream is asked.
# ---------------------------------------------------------------------------

def test_scan_writes_an_audit_row_before_calling_upstream(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        seen: list[int] = []

        def _agents(_request: httpx.Request) -> httpx.Response:
            seen.append(len(client.pool.audit_rows("connector.scan_requested")))
            return httpx.Response(200, json={"data": []})

        mock.get(f"{ANTHROPIC}/v1/agents").mock(side_effect=_agents)
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert resp.status_code == 200, resp.text
        assert seen == [1]
        (row,) = client.pool.audit_rows("connector.scan_requested")
        assert row["tenant"] == "tenant-a"
        assert row["actor"] == "alice"
        assert row["detail"] == {"connector_id": conn_id, "provider_id": "claude"}


# ---------------------------------------------------------------------------
# 4. Wire traces are superadmin-only.
# ---------------------------------------------------------------------------

def _mock_good_claude(mock: respx.MockRouter) -> None:
    mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [{"id": "agent_1", "name": "One"}, {"id": "agent_2", "name": "Two"}]}))
    sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": [{"id": "m1"}, {"id": "m2"}, {"id": "m3"}]}))


def test_scan_and_logs_null_wire_traces_for_non_superadmin(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_good_claude(mock)
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        for resp in (client.post("/api/v1/connectors/claude/scan", headers=_token("alice")),
                     client.get("/api/v1/connectors/claude/logs", headers=_token("alice"))):
            assert resp.status_code == 200, resp.text
            logs = resp.json()["logs"]
            assert logs
            assert [(l["endpoint"], l["status_code"], l["details"]) for l in logs] == [(None, None, None)] * len(logs)

        root = client.post("/api/v1/connectors/claude/scan", headers=_token("root"))
        assert root.status_code == 200, root.text
        assert [(l["endpoint"], l["status_code"]) for l in root.json()["logs"]] == [
            ("GET https://api.anthropic.com/v1/agents", 200),
            ("GET https://api.anthropic.com/v1/sessions", 200),
            ("GET https://api.anthropic.com/v1/models", 200),
        ]


# ---------------------------------------------------------------------------
# 5. Results contain only what this scan observed.
# ---------------------------------------------------------------------------

def test_live_scan_reports_observed_counts_and_nothing_unobserved(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_good_claude(mock)
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("root"))
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "success"
        assert body["records_scanned"] == {"agents": 2, "sessions": 0, "models": 3, "environments": None, "tools": None}
        assert body["policies_evaluated"] is None
        assert len(body["logs"]) == 3
        text = " ".join(l["message"] for l in body["logs"])
        assert "CEL" not in text and "Daily News Jokester" not in text


def test_live_scan_upstream_failure_is_reported_as_error_with_the_real_calls(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(401, json={"error": "nope"}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(401, json={"data": [], "next_page": None}))
        mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(401, json={"error": "nope"}))
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-bad"})
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("root"))
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["status"] == "error"
        assert body["records_scanned"]["agents"] is None and body["records_scanned"]["models"] is None
        assert [(l["level"], l["status_code"]) for l in body["logs"]] == [("error", 401), ("error", 401), ("error", 401)]


def test_live_scan_of_a_provider_without_a_live_scanner_is_501(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        everything = mock.route().mock(return_value=httpx.Response(200))
        _create(client, _token("alice"), "github", {"organization": "o", "personal_access_token": "t"})
        resp = client.post("/api/v1/connectors/github/scan", headers=_token("alice"))
        assert resp.status_code == 501
        assert _error_code(resp) == "scan_unsupported"
        assert not everything.called


def test_live_logs_never_invent_a_result_when_no_scan_ran(monkeypatch):
    with _client(monkeypatch) as client:
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = client.get("/api/v1/connectors/claude/logs", headers=_token("alice"))
        assert resp.status_code == 404
        assert _error_code(resp) == "never_scanned"


def test_sync_result_has_no_observation_shaped_defaults():
    fields = SyncResult.model_fields
    for name in ("duration_ms", "status", "records_scanned", "policies_evaluated"):
        assert fields[name].is_required(), f"SyncResult.{name} must not default to an invented observation"


# ---------------------------------------------------------------------------
# 6. "Verified" only on a real successful probe.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("status, valid", [(200, True), (401, False)])
def test_stored_claude_test_is_valid_only_when_the_probe_succeeds(monkeypatch, status, valid):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        probe = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(status, json={"data": []}))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice"))
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert (body["valid"], body["scopes_ok"]) == (valid, valid)
        assert _sent_keys(probe) == ["sk-ant-alice"]
        if not valid:
            assert "401" in body["error_msg"]


def test_stored_claude_test_when_upstream_is_unreachable_is_not_verified(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/models").mock(side_effect=httpx.ConnectError("down"))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        body = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()
        assert body["valid"] is False and body["scopes_ok"] is False
        assert "Verified" not in (body.get("message") or "")


def test_supplied_credentials_test_does_not_persist(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        probe = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        before = client.get("/api/v1/connectors", headers=_token("alice")).json()
        for prefix in ("/api/v1", "/api", ""):
            resp = client.post(f"{prefix}/connectors/providers/claude/test", headers=_token("alice"),
                               json={"credentials": {"api_key": "sk-ant-trial"}})
            assert resp.status_code == 200, resp.text
            assert (resp.json()["valid"], resp.json()["scopes_ok"]) == (True, True)
        assert _sent_keys(probe) == ["sk-ant-trial"] * 3
        assert client.get("/api/v1/connectors", headers=_token("alice")).json() == before
        assert client.pool.connectors == {}


def test_supplied_credentials_test_for_a_provider_without_a_verifier_is_501(monkeypatch):
    with _client(monkeypatch) as client:
        resp = client.post("/api/v1/connectors/providers/aws_iam/test", headers=_token("alice"),
                           json={"credentials": {"account_id": "1"}})
        assert resp.status_code == 501
        assert _error_code(resp) == "test_unsupported"


# ---------------------------------------------------------------------------
# 7. AI connectors are not seeded "connected" for a live tenant.
# ---------------------------------------------------------------------------

def test_live_tenant_is_not_seeded_with_claude_or_openai_connectors(monkeypatch):
    with _client(monkeypatch) as client:
        providers = {c["provider_id"] for c in client.get("/api/v1/connectors", headers=_token("alice")).json()["connectors"]}
        assert not providers & {"claude", "openai"}


def test_fixture_tenant_keeps_demo_claude_and_openai_connectors(monkeypatch):
    with _client(monkeypatch, live=False) as client:
        providers = {c["provider_id"] for c in client.get("/api/v1/connectors", headers=_token("alice")).json()["connectors"]}
        assert {"claude", "openai"} <= providers


# ---------------------------------------------------------------------------
# 8. Containment truth beats a row-supplied operational_state.
# ---------------------------------------------------------------------------

def _row(**overrides: Any) -> dict[str, Any]:
    row = {
        "id": "00000000-0000-0000-0000-000000000001", "name": "a", "origin": "Custom", "owner": "o",
        "tenant_id": "tenant-test", "lifecycle_state": "active", "last_transition_at": "2026-09-28T12:00:00Z",
        "created_at": "2026-09-01T00:00:00Z", "namespace": "ns", "service_account": "sa",
        "operational_state": {"runtime_status": "running"},
    }
    row.update(overrides)
    return row


_COMPLIANCE = ComplianceSummaryInline(total_controls=1, passing=1, failing=0, pending=0, posture_score=100.0)


def test_kernel_frozen_agent_never_reads_running_from_its_row():
    overlay = {"state": "stunned", "stunned_at": "2026-09-29T00:00:00Z", "kernel_state": "frozen"}
    resp = api_compat._agent_response_from_row(_row(), _COMPLIANCE, discovered_overlay=overlay)
    assert resp.operational_state.runtime_status == "stopped"


def test_suspended_agent_never_reads_running_from_its_row():
    resp = api_compat._agent_response_from_row(_row(lifecycle_state="suspended"), _COMPLIANCE)
    assert resp.operational_state.runtime_status == "stopped"


# ---------------------------------------------------------------------------
# 9. OpenAI needs an org Admin key, and old admin_api_key credentials still work.
# ---------------------------------------------------------------------------

def test_openai_field_spec_asks_for_an_admin_key(monkeypatch):
    with _client(monkeypatch) as client:
        providers = client.get("/api/v1/connectors/providers", headers=_token("alice")).json()["providers"]
        openai = next(p for p in providers if p["provider_id"] == "openai")
        fields = {f["name"]: f for f in openai["wizard_config"]["fields"]}
        assert "Admin" in fields["api_key"]["label"]
        assert fields["api_key"]["placeholder"].startswith("sk-admin-")


@pytest.mark.parametrize("field", ["api_key", "admin_api_key"])
def test_openai_stored_test_probes_the_admin_api_with_the_stored_key(monkeypatch, field):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        probe = mock.get(f"{OPENAI}/v1/organization/admin_api_keys").mock(return_value=httpx.Response(200, json={"data": []}))
        conn_id = _create(client, _token("alice"), "openai", {field: "sk-admin-alice"})
        body = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()
        assert (body["valid"], body["scopes_ok"]) == (True, True)
        assert _sent_keys(probe) == ["Bearer sk-admin-alice"]


def test_openai_project_key_rejected_by_admin_api_is_not_valid(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{OPENAI}/v1/organization/admin_api_keys").mock(return_value=httpx.Response(403, json={}))
        conn_id = _create(client, _token("alice"), "openai", {"api_key": "sk-proj-not-admin"})
        body = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()
        assert body["scopes_ok"] is False
        assert "403" in body["error_msg"]


# ---------------------------------------------------------------------------
# 10. Timestamps are observations: stamped only when the thing happened.
# ---------------------------------------------------------------------------

def _row_for(client: TestClient, headers: dict[str, str], conn_id: str) -> dict[str, Any]:
    conns = client.get("/api/v1/connectors", headers=headers).json()["connectors"]
    return next(c for c in conns if c["connector_id"] == conn_id)


def test_live_new_connector_has_no_invented_test_scan_or_expiry(monkeypatch):
    with _client(monkeypatch) as client:
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        row = _row_for(client, _token("alice"), conn_id)
        assert row["last_tested_at"] is None
        assert row["last_scan_at"] is None
        assert row["credential_expires_at"] is None


def test_live_new_connector_keeps_a_caller_supplied_expiry(monkeypatch):
    with _client(monkeypatch) as client:
        resp = client.post("/api/v1/connectors", headers=_token("alice"), json={
            "provider_id": "claude", "credentials": {"api_key": "k"}, "credential_expires_at": "2031-05-05T00:00:00Z"})
        row = _row_for(client, _token("alice"), resp.json()["connector_id"])
        assert row["credential_expires_at"] == "2031-05-05T00:00:00Z"


def test_live_updating_a_connector_does_not_claim_it_was_tested(monkeypatch):
    with _client(monkeypatch) as client:
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice-2"})
        assert _row_for(client, _token("alice"), conn_id)["last_tested_at"] is None


def test_fixture_new_connector_keeps_demo_timestamps(monkeypatch):
    with _client(monkeypatch, live=False) as client:
        conn_id = _create(client, _token("alice"), "okta", {"api_token": "t"})
        row = _row_for(client, _token("alice"), conn_id)
        assert row["last_tested_at"] and row["last_scan_at"] and row["credential_expires_at"]


@pytest.mark.parametrize("agents_status, models_status, expected", [
    (401, 401, "error"),
    (200, 401, "warning"),
])
def test_live_unsuccessful_scan_does_not_stamp_last_scan_at_and_records_why(monkeypatch, agents_status, models_status, expected):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(agents_status, json={"data": []}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(agents_status, json={"data": [], "next_page": None}))
        mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(models_status, json={"data": []}))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert resp.json()["status"] == expected
        row = _row_for(client, _token("alice"), conn_id)
        assert row["last_scan_at"] is None
        assert row["last_scan_status"] == expected
        assert "401" in row["last_scan_error"]


def test_live_successful_scan_stamps_last_scan_at_with_the_scan_time(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_good_claude(mock)
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        body = client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()
        row = _row_for(client, _token("alice"), conn_id)
        assert body["status"] == "success"
        assert row["last_scan_at"] == body["synced_at"]
        assert (row["last_scan_status"], row["last_scan_error"]) == ("success", None)


def test_live_failed_scan_after_a_success_keeps_the_last_successful_time(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        agents = mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": []}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        models = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        first = client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()
        agents.mock(return_value=httpx.Response(500))
        sessions.mock(return_value=httpx.Response(500))
        models.mock(return_value=httpx.Response(500))
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        row = _row_for(client, _token("alice"), conn_id)
        assert row["last_scan_at"] == first["synced_at"]
        assert row["last_scan_status"] == "error"


def test_live_501_test_does_not_stamp_last_tested_at(monkeypatch):
    with _client(monkeypatch) as client:
        conn_id = _create(client, _token("alice"), "okta", {"api_token": "t"})
        resp = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice"))
        assert resp.status_code == 501
        assert _row_for(client, _token("alice"), conn_id)["last_tested_at"] is None


def test_live_test_that_never_reached_upstream_does_not_stamp_last_tested_at(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/models").mock(side_effect=httpx.ConnectError("down"))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice"))
        assert _row_for(client, _token("alice"), conn_id)["last_tested_at"] is None


@pytest.mark.parametrize("status", [200, 401])
def test_live_test_with_a_probe_verdict_stamps_last_tested_at(monkeypatch, status):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(status, json={"data": []}))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice"))
        assert _row_for(client, _token("alice"), conn_id)["last_tested_at"] is not None


def test_toggle_does_not_stamp_last_tested_at(monkeypatch):
    with _client(monkeypatch) as client:
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        for enabled in (False, True):
            resp = client.post(f"/api/v1/connectors/{conn_id}/toggle", headers=_token("alice"), json={"enabled": enabled})
            assert resp.status_code == 200, resp.text
            assert resp.json()["last_tested_at"] is None


# ---------------------------------------------------------------------------
# 11. Disconnect forgets the credentials and the stored scan results.
# ---------------------------------------------------------------------------

def test_disconnect_then_reenable_does_not_reuse_the_old_key(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_good_claude(mock)
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        assert client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).status_code == 200
        calls_before = len(mock.calls)
        assert client.delete(f"/api/v1/connectors/{conn_id}", headers=_token("alice")).status_code == 200
        assert client.post(f"/api/v1/connectors/{conn_id}/toggle", headers=_token("alice"), json={"enabled": True}).status_code == 200

        body = client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()
        assert body["valid"] is False
        scan = client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()
        assert scan["status"] == "error"
        assert len(mock.calls) == calls_before
        assert client.pool.row("tenant-a", conn_id)["credentials_ref"] is None


def test_disconnect_drops_the_stored_scan_result(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_good_claude(mock)
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        client.delete(f"/api/v1/connectors/{conn_id}", headers=_token("alice"))
        for key in (conn_id, "claude"):
            resp = client.get(f"/api/v1/connectors/{key}/logs", headers=_token("alice"))
            assert resp.status_code == 404
            assert _error_code(resp) == "never_scanned"
