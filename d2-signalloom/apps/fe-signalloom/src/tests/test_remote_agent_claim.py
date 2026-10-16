"""Claiming a remote provider agent (Anthropic / OpenAI) into the caller's tenant.

``POST /api/v1/connectors/{provider_id}/remote-agents/{external_id}/claim``
links a row continuous sync observed in ``public.remote_agents`` to an
``agent_registry`` record carrying the provider provenance. Live mode uses
``FakeRemoteAgentPool`` (tenant-scoped tables, every statement tagged), provider
HTTP is respx, exactly as test_remote_agents_api.py.
"""
from __future__ import annotations

import httpx
import respx

from tests.test_connectors_live_honesty import ANTHROPIC, _client, _create, _token

PREFIXES = ("/api/v1", "/api", "")


def _agent(i: str, name: str) -> dict:
    return {"id": i, "type": "agent", "name": name, "model": {"id": "claude-opus-4-7"}, "version": 2,
            "updated_at": "2026-10-02T00:00:00Z", "archived_at": None}


def _session(i: str, status: str) -> dict:
    return {"id": i, "type": "session", "title": "Nightly triage", "status": status,
            "agent": {"id": "agent_1", "name": "Triage", "version": 2, "model": {"id": "claude-sonnet-4-6"}},
            "updated_at": "2026-10-03T00:00:00Z"}


def _mock_claude(mock: respx.MockRouter, agents: list[dict], sessions: list[dict]) -> None:
    mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": agents, "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": sessions, "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": [{"id": "m"}]}))


def _scan(client, who: str) -> None:
    resp = client.post("/api/v1/connectors/claude/scan", headers=_token(who))
    assert resp.status_code == 200, resp.text


def _claim(client, who: str, external_id: str, provider: str = "claude", prefix: str = "/api/v1") -> httpx.Response:
    return client.post(f"{prefix}/connectors/{provider}/remote-agents/{external_id}/claim", headers=_token(who))


def _claimed_audits(client) -> list[dict]:
    return client.pool.audit_rows("agent.claimed")


def test_claiming_a_synced_agent_creates_a_registry_agent_with_provenance_and_audits_it(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [_session("sess_1", "idle")])
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")

        resp = _claim(client, "alice", "agent_1")
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["created"] is True
        assert (body["provider_id"], body["connector_id"], body["external_id"], body["kind"], body["model"]) == (
            "claude", conn_id, "agent_1", "agent", "claude-opus-4-7")
        assert body["display_name"] == "Triage"
        # Name is tenant-qualified so it cannot collide with another tenant's claim
        # of the same provider id, whichever registry uniqueness constraint holds.
        assert body["agent_name"] == "claude:agent_1@tenant-a"
        agent_id = body["agent_id"]

        reg = client.pool.registry[agent_id]
        assert reg["tenant_id"] == "tenant-a"
        assert reg["name"] == "claude:agent_1@tenant-a"
        assert reg["model_provider"] == "anthropic" and reg["model_name"] == "claude-opus-4-7"
        assert reg["lifecycle_state"] == "enrolled"
        assert reg["owner"] == "alice"
        assert reg["config"]["remote_agent"] == {
            "provider_id": "claude", "connector_id": conn_id, "external_id": "agent_1",
            "kind": "agent", "model": "claude-opus-4-7"}

        audits = _claimed_audits(client)
        assert len(audits) == 1
        detail = audits[0]["detail"]
        assert audits[0]["tenant"] == "tenant-a" and audits[0]["actor"] == "alice"
        assert {k: detail[k] for k in ("action", "source", "provider_id", "connector_id", "external_id", "kind", "model")} == {
            "action": "claimed", "source": "remote_agent", "provider_id": "claude", "connector_id": conn_id,
            "external_id": "agent_1", "kind": "agent", "model": "claude-opus-4-7"}

        listed = client.get("/api/v1/connectors/claude/remote-agents", headers=_token("alice")).json()["agents"]
        by_id = {a["external_id"]: a for a in listed}
        assert by_id["agent_1"]["claimed_agent_id"] == agent_id
        assert by_id["agent_1"]["claimed_at"] is not None
        assert by_id["sess_1"]["claimed_agent_id"] is None


def test_claiming_twice_returns_the_same_agent_without_duplicating_or_reauditing(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")

        first = _claim(client, "alice", "agent_1")
        second = _claim(client, "alice", "agent_1")
        assert first.status_code == 201, first.text
        assert second.status_code == 200, second.text
        assert second.json()["created"] is False
        assert second.json()["agent_id"] == first.json()["agent_id"]
        assert len([r for r in client.pool.registry.values() if r["tenant_id"] == "tenant-a"]) == 1
        assert len(_claimed_audits(client)) == 1

        # A re-scan (the provider still lists it) keeps the link.
        _scan(client, "alice")
        listed = client.get("/api/v1/connectors/claude/remote-agents", headers=_token("alice")).json()["agents"]
        assert listed[0]["claimed_agent_id"] == first.json()["agent_id"]


def test_another_tenant_cannot_claim_or_see_the_claim(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")

        # bob has no claude connector at all.
        resp = _claim(client, "bob", "agent_1")
        assert resp.status_code == 404 and resp.json()["error"]["code"] == "connector_not_configured"

        # bob connects his own claude connector, but has never observed agent_1.
        _mock_claude(mock, [], [])
        _create(client, _token("bob"), "claude", {"api_key": "sk-ant-bob"})
        _scan(client, "bob")
        resp = _claim(client, "bob", "agent_1")
        assert resp.status_code == 404 and resp.json()["error"]["code"] == "remote_agent_not_found"
        assert client.pool.registry == {} and _claimed_audits(client) == []


def test_the_same_provider_agent_in_two_tenants_claims_two_distinct_agents(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [])
        for who in ("alice", "bob"):
            _create(client, _token(who), "claude", {"api_key": f"sk-ant-{who}"})
            _scan(client, who)
        a = _claim(client, "alice", "agent_1").json()
        b = _claim(client, "bob", "agent_1").json()
        assert a["agent_id"] != b["agent_id"] and a["agent_name"] != b["agent_name"]
        assert {r["tenant_id"] for r in client.pool.registry.values()} == {"tenant-a", "tenant-b"}


def test_an_unknown_external_id_is_404(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")
        resp = _claim(client, "alice", "agent_nope")
        assert resp.status_code == 404 and resp.json()["error"]["code"] == "remote_agent_not_found"
        assert client.pool.registry == {} and _claimed_audits(client) == []


def test_a_gone_agent_is_409(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "One"), _agent("agent_2", "Two")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")
        _mock_claude(mock, [_agent("agent_1", "One")], [])
        _scan(client, "alice")
        resp = _claim(client, "alice", "agent_2")
        assert resp.status_code == 409 and resp.json()["error"]["code"] == "remote_agent_gone"
        assert client.pool.registry == {} and _claimed_audits(client) == []


def test_the_route_is_mounted_on_all_three_prefixes_and_requires_a_token(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")
        for prefix in PREFIXES:
            anon = client.post(f"{prefix}/connectors/claude/remote-agents/agent_1/claim")
            assert anon.status_code == 401, (prefix, anon.status_code)
        codes = [_claim(client, "alice", "agent_1", prefix=p).status_code for p in PREFIXES]
        assert codes == [201, 200, 200]


def test_discovery_marks_a_claimed_remote_agent_governed_and_links_it(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "One"), _agent("agent_2", "Two")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        _scan(client, "alice")
        agent_id = _claim(client, "alice", "agent_1").json()["agent_id"]
        rows = client.get("/api/v1/discovery/workloads", headers=_token("alice")).json()
        rows = rows["workloads"] if isinstance(rows, dict) else rows
        remote = {w["id"]: w for w in rows if w.get("metadata", {}).get("provider_id") == "claude"}
        assert remote["agent_1"]["status"] == "governed"
        assert remote["agent_1"]["metadata"]["claimed_agent_id"] == agent_id
        assert remote["agent_2"]["status"] == "discovered"
        assert remote["agent_2"]["metadata"]["claimed_agent_id"] is None


def test_fixture_mode_has_no_remote_state_so_a_claim_is_404_and_writes_nothing(monkeypatch):
    # Same contract as GET remote-agents in fixture mode: no sync runs, no remote
    # state is invented, so there is nothing to claim.
    with _client(monkeypatch, live=False) as client:
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        resp = _claim(client, "alice", "agent_1")
        assert resp.status_code == 404 and resp.json()["error"]["code"] == "remote_agent_not_found"
        missing = _claim(client, "alice", "agent_1", provider="no-such-provider")
        assert missing.status_code == 404 and missing.json()["error"]["code"] == "connector_not_configured"
