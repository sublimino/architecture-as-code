"""Exercise the served A2A surface: the well-known agent card must be the
committed contract, and message/send must run the real triage skill (the
direct TROUBLESHOOT path) through the ADK runtime."""

import json

from starlette.testclient import TestClient

from olly_sentinel import contracts, pipeline
from olly_sentinel.agent import SentinelRuntime
from olly_sentinel.main import build_app
from tests.test_pipeline_agent import CANNED_HITS

WELL_KNOWN = "/.well-known/agent-card.json"


def make_client(monkeypatch) -> TestClient:
    async def fake_mcp_call(client, tool, body):
        if tool == "elk_search_logs":
            return CANNED_HITS[body["index_pattern"]]
        return {}  # enriched sources answer empty in this hermetic test

    async def fake_mcp_search(client, pattern, query):
        return CANNED_HITS[pattern]

    monkeypatch.setattr(pipeline, "mcp_call", fake_mcp_call)
    monkeypatch.setattr(pipeline, "mcp_search", fake_mcp_search)
    # ADK's to_a2a registers routes during the lifespan; the caller must use
    # the client as a context manager.
    return TestClient(build_app(SentinelRuntime()))


def test_well_known_card_matches_committed_contract(monkeypatch):
    with make_client(monkeypatch) as client:
        resp = client.get(WELL_KNOWN)
        assert resp.status_code == 200
        served = resp.json()
    committed = contracts.load(contracts.AGENT_CARD)
    assert served["name"] == committed["name"]
    assert [s["id"] for s in served["skills"]] == [s["id"] for s in committed["skills"]]
    blob = json.dumps(served)
    assert "eems" in blob and "bearer" in blob, "EEMS auth declaration must survive serving"


def test_health_and_metrics_routes(monkeypatch):
    with make_client(monkeypatch) as client:
        assert client.get("/healthz").text == "ok"
        assert "olly_incidents_received_total" in client.get("/metrics").text


def test_a2a_message_send_triage(monkeypatch):
    request = {
        "jsonrpc": "2.0",
        "id": "1",
        "method": "message/send",
        "params": {
            "message": {
                "role": "user",
                "messageId": "m-1",
                "parts": [{"kind": "text", "text": json.dumps({
                    "correlation_id": "corr-a2a-test",
                    "app_id": "inventory-service",
                })}],
            }
        },
    }
    with make_client(monkeypatch) as client:
        resp = client.post("/", json=request)
    assert resp.status_code == 200
    body = resp.json()
    assert "result" in body, body
    text = json.dumps(body["result"])
    assert "fault_domain" in text
    assert "corr-a2a-test" in text
    assert "Sup3rSecretPlantedPw" not in text


def test_a2a_rejects_malformed_request(monkeypatch):
    request = {
        "jsonrpc": "2.0",
        "id": "2",
        "method": "message/send",
        "params": {
            "message": {
                "role": "user",
                "messageId": "m-2",
                "parts": [{"kind": "text", "text": "not json at all"}],
            }
        },
    }
    with make_client(monkeypatch) as client:
        resp = client.post("/", json=request)
    assert resp.status_code == 200
    assert "triage request rejected" in json.dumps(resp.json())
