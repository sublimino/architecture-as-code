"""The remote agent surface of the connectors API: read, stream, webhook, scan and discovery.

Live mode uses ``FakeRemoteAgentPool`` through the honesty suite's client (a
pool, no DSN, so the background loop never starts); provider HTTP is respx.
"""
from __future__ import annotations

import base64
import json
import secrets
from datetime import datetime, timezone

import httpx
import respx
from standardwebhooks import Webhook

import remote_agent_sync
from routers import connectors as connectors_router
from tests.test_connectors_live_honesty import ANTHROPIC, _client, _create, _token

WEBHOOK_KEY = "whsec_" + base64.b64encode(secrets.token_bytes(24)).decode()


def _agent(i: str, name: str) -> dict:
    return {"id": i, "type": "agent", "name": name, "model": {"id": "claude-opus-4-7"}, "version": 2,
            "updated_at": "2026-10-02T00:00:00Z", "archived_at": None}


def _session(i: str, status: str) -> dict:
    return {"id": i, "type": "session", "title": "Nightly triage", "status": status,
            "agent": {"id": "agent_1", "name": "Triage", "version": 2, "model": {"id": "claude-sonnet-4-6"}},
            "updated_at": "2026-10-03T00:00:00Z"}


def _mock_claude(mock: respx.MockRouter, agents: list[dict], sessions: list[dict]):
    mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": agents, "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": sessions, "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": [{"id": "m"}]}))


def _remote(client, who: str, provider: str = "claude") -> httpx.Response:
    return client.get(f"/api/v1/connectors/{provider}/remote-agents", headers=_token(who))


# ---------------------------------------------------------------------------
# Read API and the manual scan share the sync's diff path
# ---------------------------------------------------------------------------

def test_remote_agents_of_an_unconfigured_connector_is_404(monkeypatch):
    with _client(monkeypatch) as client:
        resp = _remote(client, "alice")
        assert resp.status_code == 404
        assert resp.json()["error"]["code"] == "connector_not_configured"


def test_a_scan_stores_the_listing_and_the_read_api_returns_it_for_that_tenant_only(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [_session("sess_1", "idle")])
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        scan = client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()
        assert scan["records_scanned"]["agents"] == 1 and scan["records_scanned"]["sessions"] == 1

        body = _remote(client, "alice").json()
        assert (body["provider_id"], body["connector_id"]) == ("claude", conn_id)
        assert body["sync_state"]["mode"] == "poll" and body["sync_state"]["last_error"] is None
        by_id = {a["external_id"]: a for a in body["agents"]}
        assert set(by_id) == {"agent_1", "sess_1"}
        assert set(by_id["sess_1"]) == {"external_id", "kind", "name", "model", "status", "version",
                                        "external_updated_at", "first_seen_at", "last_seen_at", "last_changed_at", "gone_at",
                                        "claimed_agent_id", "claimed_at"}
        assert by_id["sess_1"]["claimed_agent_id"] is None and by_id["sess_1"]["claimed_at"] is None
        assert (by_id["sess_1"]["kind"], by_id["sess_1"]["status"], by_id["sess_1"]["model"]) == (
            "session", "idle", "claude-sonnet-4-6")
        assert _remote(client, "bob").status_code == 404


def test_a_second_scan_marks_a_vanished_agent_gone_and_keeps_it_readable(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "One"), _agent("agent_2", "Two")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        _mock_claude(mock, [_agent("agent_1", "One")], [])
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        agents = {a["external_id"]: a for a in _remote(client, "alice").json()["agents"]}
        assert agents["agent_2"]["gone_at"] is not None and agents["agent_1"]["gone_at"] is None


# ---------------------------------------------------------------------------
# SSE stream
# ---------------------------------------------------------------------------

def test_the_stream_requires_a_bearer_token(monkeypatch):
    with _client(monkeypatch) as client:
        assert client.get("/api/connectors/stream").status_code == 401


def test_the_stream_replays_only_the_callers_tenant(monkeypatch):
    remote_agent_sync.EVENTS.reset()
    remote_agent_sync.EVENTS.publish("tenant-b", "remote_agent.upserted",
                                     {"provider_id": "claude", "connector_id": "c", "agent": {"name": "bob-secret"}})
    remote_agent_sync.EVENTS.publish("tenant-a", "remote_agent.gone",
                                     {"provider_id": "claude", "connector_id": "c", "external_id": "x", "gone_at": "t"})
    monkeypatch.setattr(connectors_router, "_STREAM_MAX_EVENTS", 1)
    try:
        with _client(monkeypatch) as client:
            for path in ("/api/connectors/stream", "/api/v1/connectors/stream", "/connectors/stream"):
                resp = client.get(path, headers={**_token("alice"), "Last-Event-ID": "0"})
                assert resp.status_code == 200
                assert resp.headers["content-type"].startswith("text/event-stream")
                assert resp.text.startswith("retry: 5000\n\n")
                assert "event: remote_agent.gone\n" in resp.text and "bob-secret" not in resp.text
    finally:
        remote_agent_sync.EVENTS.reset()


# ---------------------------------------------------------------------------
# Webhook
# ---------------------------------------------------------------------------

def _signed(payload: dict, key: str = WEBHOOK_KEY) -> tuple[bytes, dict[str, str]]:
    body = json.dumps(payload).encode()
    msg_id = payload["id"]
    now = datetime.now(timezone.utc)
    sig = Webhook(key).sign(msg_id, now, body.decode())
    return body, {"webhook-id": msg_id, "webhook-timestamp": str(int(now.timestamp())), "webhook-signature": sig,
                  "content-type": "application/json"}


def _event(event_id: str, kind: str, resource: str, org: str = "org_alice") -> dict:
    return {"id": event_id, "type": "event", "created_at": "2026-10-16T12:00:00Z",
            "data": {"id": resource, "type": kind, "organization_id": org, "workspace_id": "wrkspc_1"}}


def _webhook_env(monkeypatch):
    monkeypatch.setenv(connectors_router.ANTHROPIC_WEBHOOK_KEY_ENV, WEBHOOK_KEY)
    monkeypatch.setenv(connectors_router.ANTHROPIC_WEBHOOK_ORGS_ENV, "org_alice=tenant-a")
    connectors_router.reset_webhook_dedupe_for_testing()


def test_the_webhook_is_disabled_without_a_signing_key(monkeypatch):
    monkeypatch.delenv(connectors_router.ANTHROPIC_WEBHOOK_KEY_ENV, raising=False)
    with _client(monkeypatch) as client:
        body, headers = _signed(_event("evt_1", "session.status_idled", "sess_1"))
        assert client.post("/api/connectors/claude/webhook", content=body, headers=headers).status_code == 404


def test_a_bad_signature_is_400_and_fetches_nothing(monkeypatch):
    _webhook_env(monkeypatch)
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        upstream = mock.route(host="api.anthropic.com").mock(return_value=httpx.Response(200, json={}))
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        other_key = "whsec_" + base64.b64encode(secrets.token_bytes(24)).decode()
        body, headers = _signed(_event("evt_1", "session.status_idled", "sess_1"), key=other_key)
        resp = client.post("/api/connectors/claude/webhook", content=body, headers=headers)
        assert resp.status_code == 400 and resp.json()["error"]["code"] == "invalid_signature"
        tampered, good = _signed(_event("evt_2", "session.status_idled", "sess_1"))
        resp = client.post("/api/connectors/claude/webhook", content=tampered.replace(b"sess_1", b"sess_9"), headers=good)
        assert resp.status_code == 400
        assert not upstream.called
        assert client.pool.audit_rows("connector.scan_requested") == []


def test_an_unknown_organization_is_404(monkeypatch):
    _webhook_env(monkeypatch)
    with _client(monkeypatch) as client:
        body, headers = _signed(_event("evt_1", "session.status_idled", "sess_1", org="org_stranger"))
        resp = client.post("/api/connectors/claude/webhook", content=body, headers=headers)
        assert resp.status_code == 404 and resp.json()["error"]["code"] == "unknown_organization"


def test_a_verified_webhook_refetches_the_session_audits_and_dedupes(monkeypatch):
    _webhook_env(monkeypatch)
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        one = mock.get(f"{ANTHROPIC}/v1/sessions/sess_1").mock(return_value=httpx.Response(200, json=_session("sess_1", "idle")))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        body, headers = _signed(_event("evt_1", "session.status_idled", "sess_1"))
        resp = client.post("/api/connectors/claude/webhook", content=body, headers=headers)
        assert resp.status_code == 200, resp.text
        assert resp.json() == {"status": "upserted", "event_id": "evt_1"}
        assert one.calls[0].request.headers["x-api-key"] == "sk-ant-alice"
        agents = _remote(client, "alice").json()["agents"]
        assert [(a["external_id"], a["status"]) for a in agents] == [("sess_1", "idle")]
        (row,) = client.pool.audit_rows("connector.scan_requested")
        assert row["tenant"] == "tenant-a" and row["actor"] == "anthropic-webhook:org_alice"
        assert row["detail"]["trigger"] == "webhook" and row["detail"]["connector_id"] == conn_id

        again = client.post("/api/connectors/claude/webhook", content=body, headers=headers)
        assert again.json()["status"] == "duplicate" and one.call_count == 1


def test_a_deleted_session_webhook_marks_it_gone_without_a_fetch(monkeypatch):
    _webhook_env(monkeypatch)
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [], [_session("sess_1", "idle")])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        single = mock.get(f"{ANTHROPIC}/v1/sessions/sess_1").mock(return_value=httpx.Response(200, json={}))
        body, headers = _signed(_event("evt_9", "session.deleted", "sess_1"))
        assert client.post("/api/connectors/claude/webhook", content=body, headers=headers).json()["status"] == "gone"
        assert not single.called
        (agent,) = _remote(client, "alice").json()["agents"]
        assert agent["gone_at"] is not None


# ---------------------------------------------------------------------------
# Discovery: live mode lists what sync observed, never the demo rows
# ---------------------------------------------------------------------------

_FIXTURE_NAMES = {"Financial Risk Intelligence Agent", "Customer Support Triage Assistant",
                  "cloudrun-prompt-processor", "n8n-support-router", "afm-staging-collector", "prod-eu-validator"}


def test_live_discovery_lists_synced_remote_agents_and_no_fixture_rows(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage"), _agent("agent_2", "Old")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        _mock_claude(mock, [_agent("agent_1", "Triage")], [])
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))

        resp = client.get("/api/v1/discovery/workloads", headers=_token("alice"))
        assert resp.status_code == 200, resp.text
        rows = resp.json()["workloads"] if isinstance(resp.json(), dict) else resp.json()
        names = {w["name"] for w in rows}
        assert names & _FIXTURE_NAMES == set()
        remote = [w for w in rows if w.get("metadata", {}).get("provider_id") == "claude"]
        assert [(w["id"], w["name"], w["source"], w["source_label"], w["model"]) for w in remote] == [
            ("agent_1", "Triage", "external_services", "Anthropic Claude", "claude-opus-4-7")]
        assert remote[0]["metadata"]["kind"] == "agent" and remote[0]["metadata"]["remote_status"] is None
        assert remote[0]["metadata"]["connector_id"] == "conn-claude-01"

        bob = client.get("/api/v1/discovery/workloads", headers=_token("bob")).json()
        bob_rows = bob["workloads"] if isinstance(bob, dict) else bob
        assert not [w for w in bob_rows if w.get("metadata", {}).get("provider_id") == "claude"]


def test_fixture_discovery_is_unchanged(monkeypatch):
    with _client(monkeypatch, live=False) as client:
        resp = client.get("/api/v1/discovery/workloads", headers=_token("alice"))
        assert resp.status_code == 200
        rows = resp.json()["workloads"] if isinstance(resp.json(), dict) else resp.json()
        assert {"Customer Support Triage Assistant", "afm-staging-collector"} <= {w["name"] for w in rows}
