"""Tests for content-addressed remote agent snapshots, versioning, deduplication, and metadata enrichment."""
from __future__ import annotations

import httpx
import respx
import pytest

from tests.test_connectors_live_honesty import ANTHROPIC, _client, _create, _token


def _agent(i: str, name: str, system: str = "Default prompt", model: str = "claude-opus-4-7") -> dict:
    return {
        "id": i,
        "type": "agent",
        "name": name,
        "model": {"id": model},
        "version": 2,
        "system": system,
        "tools": [{"name": "web_search", "description": "Search the web"}],
        "mcp_servers": [{"name": "postgres_mcp"}],
        "skills": ["reasoning"],
        "execution_identity": {"type": "service_account"},
        "updated_at": "2026-10-02T00:00:00Z",
        "archived_at": None,
    }


def _session(i: str, status: str, system: str = "Session prompt") -> dict:
    return {
        "id": i,
        "type": "session",
        "title": "Nightly triage",
        "status": status,
        "system": system,
        "environment_id": "env_01CyCigBbDRSLTzSCyyHQ7eT",
        "agent": {"id": "agent_1", "name": "Triage", "version": 2, "model": {"id": "claude-sonnet-4-6"}},
        "updated_at": "2026-10-03T00:00:00Z",
    }


def _environment(i: str = "env_01CyCigBbDRSLTzSCyyHQ7eT", name: str = "cloud-dev") -> dict:
    return {
        "id": i,
        "type": "environment",
        "name": name,
        "config": {
            "networking": {"type": "unrestricted"},
            "packages": {"apt": ["python3-dev", "gcc"]},
        },
        "updated_at": "2026-10-01T00:00:00Z",
    }


def _mock_claude(mock: respx.MockRouter, agents: list[dict], sessions: list[dict], environments: list[dict] | None = None):
    mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": agents, "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": sessions, "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/environments").mock(return_value=httpx.Response(200, json={"data": environments or [], "next_page": None}))
    mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": [{"id": "m"}]}))


def test_snapshot_deduplication_multiple_syncs_insert_single_snapshot(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [_session("sess_1", "idle")])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})

        # First scan
        scan1 = client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert scan1.status_code == 200

        # Second scan with identical state
        scan2 = client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert scan2.status_code == 200

        # Query snapshots
        resp = client.get("/api/v1/connectors/claude/remote-agents/agent_1/snapshots", headers=_token("alice"))
        assert resp.status_code == 200, resp.text
        snapshots = resp.json()
        assert len(snapshots) == 1, f"Expected 1 snapshot due to deduplication, got {len(snapshots)}"
        assert snapshots[0]["raw_hash"] is not None
        assert snapshots[0]["external_id"] == "agent_1"


def test_snapshot_versioning_attribute_change_adds_new_snapshot(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage", system="Prompt v1", model="claude-opus-4-7")], [])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})

        # Initial scan
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))

        # Agent changes system prompt and model
        _mock_claude(mock, [_agent("agent_1", "Triage", system="Prompt v2 Security Expert", model="claude-sonnet-4-6")], [])
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))

        resp = client.get("/api/v1/connectors/claude/remote-agents/agent_1/snapshots", headers=_token("alice"))
        assert resp.status_code == 200, resp.text
        snapshots = resp.json()
        assert len(snapshots) == 2, f"Expected 2 snapshots after version change, got {len(snapshots)}"
        # Latest snapshot should have Prompt v2
        assert snapshots[0]["system_prompt"] == "Prompt v2 Security Expert"
        assert snapshots[0]["model"] == "claude-sonnet-4-6"
        assert snapshots[1]["system_prompt"] == "Prompt v1"
        assert snapshots[1]["model"] == "claude-opus-4-7"
        assert snapshots[0]["raw_hash"] != snapshots[1]["raw_hash"]


def test_snapshots_endpoint_and_history_alias(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(mock, [_agent("agent_1", "Triage")], [_session("sess_1", "idle")])
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))

        resp_snap = client.get("/api/v1/connectors/claude/remote-agents/agent_1/snapshots", headers=_token("alice"))
        assert resp_snap.status_code == 200
        resp_hist = client.get("/api/v1/connectors/claude/remote-agents/agent_1/history", headers=_token("alice"))
        assert resp_hist.status_code == 200
        assert resp_snap.json() == resp_hist.json()


def test_discovery_workloads_response_enriches_metadata(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(
            mock,
            [_agent("agent_1", "Triage", system="Act as a secure agent")],
            [_session("sess_1", "idle")],
            [_environment("env_01CyCigBbDRSLTzSCyyHQ7eT", "cloud-dev")],
        )
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))

        resp = client.get("/api/v1/discovery/workloads", headers=_token("alice"))
        assert resp.status_code == 200
        workloads = resp.json()["workloads"] if isinstance(resp.json(), dict) else resp.json()

        claude_workloads = [w for w in workloads if w.get("metadata", {}).get("provider_id") == "claude"]
        assert len(claude_workloads) >= 1
        agent_wl = next(w for w in claude_workloads if w["id"] == "agent_1")

        # Anthropic reported no owner for this agent, and none was fabricated.
        assert agent_wl.get("owner") is None

        # Exposes user_metadata, raw_hash, system_prompt, environment_config, metrics in metadata,
        # but every one of the previously-hardcoded fields is absent because the payload (and the
        # stored credentials, which carry no workspace_id in this test) never supplied them.
        meta = agent_wl["metadata"]
        assert "user_metadata" in meta
        assert meta["user_metadata"] == {}

        assert "raw_hash" in meta
        assert isinstance(meta["raw_hash"], str) and len(meta["raw_hash"]) == 64

        assert meta["system_prompt"] == "Act as a secure agent"
        assert "environment_config" in meta
        assert "metrics" in meta
        assert meta["metrics"] == {}


def test_environment_kind_sync(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        _mock_claude(
            mock,
            [],
            [],
            [_environment("env_01CyCigBbDRSLTzSCyyHQ7eT", "cloud-dev")],
        )
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-alice"})
        scan = client.post("/api/v1/connectors/claude/scan", headers=_token("alice"))
        assert scan.status_code == 200

        # Query remote agents
        resp = client.get("/api/v1/connectors/claude/remote-agents", headers=_token("alice"))
        assert resp.status_code == 200
        agents = {a["external_id"]: a for a in resp.json()["agents"]}
        assert "env_01CyCigBbDRSLTzSCyyHQ7eT" in agents
        env = agents["env_01CyCigBbDRSLTzSCyyHQ7eT"]
        assert env["kind"] == "environment"
        assert env["name"] == "cloud-dev"
        assert env["environment_config"]["network"] == "unrestricted"

        # Check snapshots endpoint
        snap_resp = client.get("/api/v1/connectors/claude/remote-agents/env_01CyCigBbDRSLTzSCyyHQ7eT/snapshots", headers=_token("alice"))
        assert snap_resp.status_code == 200
        assert len(snap_resp.json()) == 1
        assert snap_resp.json()[0]["kind"] == "environment"

