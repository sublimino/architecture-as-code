"""Organisation-scoped Anthropic keys: the workspace header and the workspace_required outcome.

Verified live 2026-10-16 with an organisation key: every request without
``anthropic-workspace-id`` answers 400 invalid_request_error "This API key is
not scoped to a workspace, so this request must include the
anthropic-workspace-id header with the ID of the workspace to use."
"""
from __future__ import annotations

import asyncio

import httpx
import pytest
import respx

import remote_agent_sync as ras
from tests.test_connectors_live_honesty import ANTHROPIC, _client, _create, _token

ORG_KEY_400 = httpx.Response(400, json={"type": "error", "error": {
    "type": "invalid_request_error",
    "message": "This API key is not scoped to a workspace, so this request must include the "
               "anthropic-workspace-id header with the ID of the workspace to use."}})
WS = "wrkspc_01ABCdef"


def _ws_header(route: respx.Route) -> list[str | None]:
    return [c.request.headers.get("anthropic-workspace-id") for c in route.calls]


@pytest.mark.parametrize("creds, expected", [
    ({"api_key": "sk-ant-x", "workspace_id": WS}, [WS]),
    ({"api_key": "sk-ant-x"}, [None]),
    ({"api_key": "sk-ant-x", "workspace_id": "  "}, [None]),
])
def test_the_supplied_credential_test_sends_the_workspace_only_when_given(monkeypatch, creds, expected):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        models = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        resp = client.post("/api/v1/connectors/providers/claude/test", headers=_token("alice"), json={"credentials": creds})
        assert resp.status_code == 200 and resp.json()["valid"] is True
        assert _ws_header(models) == expected


def test_an_organisation_key_without_a_workspace_is_workspace_required_not_a_generic_400(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=ORG_KEY_400)
        body = client.post("/api/v1/connectors/providers/claude/test", headers=_token("alice"),
                           json={"credentials": {"api_key": "sk-ant-org"}}).json()
        assert body["valid"] is False and body["error_code"] == "workspace_required"
        assert body["error_msg"] == ("This Anthropic key is organisation-scoped: enter the Workspace ID "
                                     "(Console → Settings → Workspaces) and test again.")
        assert "Unexpected HTTP 400" not in body["error_msg"]


def test_a_stored_connector_test_and_scan_send_the_workspace_from_its_credentials(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        models = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        agents = mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        sessions = mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        conn_id = _create(client, _token("alice"), "claude", {"api_key": "sk-ant-org", "workspace_id": WS})
        assert client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice")).json()["valid"] is True
        assert client.post("/api/v1/connectors/claude/scan", headers=_token("alice")).json()["status"] == "success"
        assert _ws_header(models) == [WS, WS]
        assert _ws_header(agents) == [WS] and _ws_header(sessions) == [WS]


def test_a_workspace_in_connector_metadata_is_used_too(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        models = mock.get(f"{ANTHROPIC}/v1/models").mock(return_value=httpx.Response(200, json={"data": []}))
        resp = client.post("/api/v1/connectors", headers=_token("alice"), json={
            "provider_id": "claude", "credentials": {"api_key": "sk-ant-org"}, "metadata": {"workspace_id": WS}})
        conn_id = resp.json()["connector_id"]
        client.post(f"/api/v1/connectors/{conn_id}/test", headers=_token("alice"))
        assert _ws_header(models) == [WS]


def test_a_scan_with_an_organisation_key_reports_workspace_required(monkeypatch):
    with _client(monkeypatch) as client, respx.mock(assert_all_called=False) as mock:
        for path in ("/v1/agents", "/v1/sessions", "/v1/models"):
            mock.get(f"{ANTHROPIC}{path}").mock(return_value=ORG_KEY_400)
        _create(client, _token("alice"), "claude", {"api_key": "sk-ant-org"})
        body = client.post("/api/v1/connectors/claude/scan", headers=_token("root")).json()
        assert body["status"] == "error"
        assert {log["message"] for log in body["logs"]} == {ras.WORKSPACE_REQUIRED_MESSAGE}
        assert {(log["details"] or {}).get("error_code") for log in body["logs"]} == {"workspace_required"}
        state = client.get("/api/v1/connectors/claude/remote-agents", headers=_token("alice")).json()["sync_state"]
        assert ras.WORKSPACE_REQUIRED_MESSAGE in state["last_error"] and "HTTP 400" not in state["last_error"]


@pytest.mark.parametrize("creds, expected", [({"api_key": "k", "workspace_id": WS}, WS), ({"api_key": "k"}, None)])
def test_the_adapter_sends_the_workspace_on_listing_fetch_and_stream(creds, expected):
    adapter = ras.AnthropicAdapter()

    async def scenario():
        with respx.mock(assert_all_called=False) as mock:
            agents = mock.get(f"{ANTHROPIC}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
            mock.get(f"{ANTHROPIC}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
            one = mock.get(f"{ANTHROPIC}/v1/sessions/s1").mock(return_value=httpx.Response(404))
            stream = mock.get(f"{ANTHROPIC}/v1/sessions/s1/events/stream").mock(
                return_value=httpx.Response(200, content=b"data: {\"type\":\"session.status_idle\"}\n\n"))
            async with httpx.AsyncClient() as http:
                await adapter.list_inventory(http, creds, ras.utc_now)
                await adapter.fetch_one(http, creds, "session", "s1", ras.utc_now)
                events = [e async for e in adapter.stream_status_events(http, creds, "s1")]
            return _ws_header(agents) + _ws_header(one) + _ws_header(stream), events
    headers, events = asyncio.run(scenario())
    assert headers == [expected] * 3 and events == ["session.status_idle"]


def test_a_stream_refused_for_want_of_a_workspace_is_workspace_required():
    async def scenario():
        with respx.mock(assert_all_called=False) as mock:
            mock.get(f"{ANTHROPIC}/v1/sessions/s1/events/stream").mock(return_value=ORG_KEY_400)
            async with httpx.AsyncClient() as http:
                try:
                    async for _ in ras.AnthropicAdapter().stream_status_events(http, {"api_key": "k"}, "s1"):
                        pass
                except ras.ProviderError as exc:
                    return exc.code, str(exc)
    assert asyncio.run(scenario()) == ("workspace_required", ras.WORKSPACE_REQUIRED_MESSAGE)


def test_the_claude_field_spec_says_when_the_workspace_is_required():
    from routers.connectors import STANDARD_PROVIDERS

    claude = next(p for p in STANDARD_PROVIDERS if p.provider_id == "claude")
    field = next(f for f in claude.wizard_config.fields if f.name == "workspace_id")
    assert field.required is False
    assert "organisation-scoped" in field.label and "Console → Settings → Workspaces" in (field.help_text or "")
